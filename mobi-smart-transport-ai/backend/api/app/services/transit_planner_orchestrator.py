from __future__ import annotations

from collections.abc import Callable
from typing import Any

from app.schemas.v3 import (
    DestinationResolveStatus,
    FallbackSource,
    RoutePlanCandidate,
    RoutePlanReadiness,
    RoutePlanResponse,
    RoutePlanSource,
    RoutePlanStatus,
    RoutePlanVerificationStatus,
)
from app.services.cheongju_route_planner import CheongjuRoutePlanner, _mock_route_sequences
from app.services.destination_candidate_resolver import DestinationCandidateResolver
from app.services.odsay_client import OdsayClient, OdsayUnavailableError
from app.services.odsay_route_mapper import OdsayRouteMapper
from app.services.route_plan_enricher import RoutePlanEnricher
from app.services.route_ranker import RouteRanker
from app.services.route_stop_sequence_cache import RouteStopSequenceCache
from services.public_data.public_data_client import BusRouteService


class TransitPlannerOrchestrator:
    """Combines ODsay primary candidates with the existing Cheongju planners."""

    def __init__(
        self,
        *,
        resolver: DestinationCandidateResolver | None = None,
        route_service: BusRouteService | None = None,
        arrival_fetcher: Callable | None = None,
        odsay_client: OdsayClient | None = None,
        odsay_mapper: OdsayRouteMapper | None = None,
        enricher: RoutePlanEnricher | None = None,
        ranker: RouteRanker | None = None,
    ) -> None:
        self._resolver = resolver or DestinationCandidateResolver()
        self._route_service = route_service or BusRouteService()
        self._arrival_fetcher = arrival_fetcher
        self._local_planner = CheongjuRoutePlanner(
            resolver=self._resolver,
            route_service=self._route_service,
            arrival_fetcher=arrival_fetcher,
        )
        self._odsay_client = odsay_client or OdsayClient()
        self._odsay_mapper = odsay_mapper or OdsayRouteMapper()
        self._enricher = enricher or RoutePlanEnricher(
            sequence_cache=RouteStopSequenceCache(
                route_service=self._route_service,
                mock_sequences=_mock_route_sequences(),
            ),
            arrival_fetcher=arrival_fetcher,
        )
        self._ranker = ranker or RouteRanker()

    def plan(
        self,
        *,
        heard_text: str,
        origin_lat: float | None = None,
        origin_lng: float | None = None,
        live: bool = False,
    ) -> RoutePlanResponse:
        local_response = self._local_planner.plan(
            heard_text=heard_text,
            origin_lat=origin_lat,
            origin_lng=origin_lng,
            live=live,
        )
        if not live or not self._odsay_enabled():
            return local_response
        if (
            local_response.destination.status != DestinationResolveStatus.RESOLVED
            or origin_lat is None
            or origin_lng is None
            or local_response.destination.topCandidate is None
            or local_response.destination.topCandidate.latitude is None
            or local_response.destination.topCandidate.longitude is None
        ):
            return local_response

        destination = local_response.destination.topCandidate
        try:
            result = self._odsay_client.search_public_transit_path(
                origin_lat=origin_lat,
                origin_lng=origin_lng,
                destination_lat=destination.latitude,
                destination_lng=destination.longitude,
            )
            mapped = self._odsay_mapper.map_result(result, destination_name=destination.name)
            enriched = [self._enricher.enrich(candidate, live=live) for candidate in mapped]
        except OdsayUnavailableError as exc:
            return _local_fallback_response(local_response, warning="ODsay unavailable; local planner fallback used", error=exc)
        except Exception as exc:
            return _local_fallback_response(local_response, warning="ODsay unavailable; local planner fallback used", error=exc)

        if not enriched:
            return _local_fallback_response(
                local_response,
                warning="ODsay returned no usable bus candidates; local planner fallback used",
            )

        candidates = _dedupe_candidates([*enriched, *local_response.plans])
        plans = self._ranker.rank(candidates)[:5]
        recommended = plans[0] if plans else None
        warnings = _dedupe([warning for plan in plans for warning in plan.warnings])
        return RoutePlanResponse(
            status=RoutePlanStatus.RESOLVED if recommended else RoutePlanStatus.NO_ROUTE,
            readiness=RoutePlanReadiness.READY if recommended else RoutePlanReadiness.NO_ROUTE,
            heardText=heard_text,
            destination=local_response.destination,
            plans=plans,
            recommendedPlan=recommended,
            alternatives=plans[1:],
            agentMessage=recommended.boardingInstruction if recommended else local_response.question,
            question=None if recommended else local_response.question,
            fallbackSource=_strongest_source([local_response.fallbackSource, *(plan.fallbackSource for plan in plans)]),
            warnings=warnings,
            rawProviderEvidence={
                "provider": "ODSAY",
                "odsayCandidates": len(enriched),
                "localCandidates": len(local_response.plans),
            },
        )

    def _odsay_enabled(self) -> bool:
        enabled = getattr(self._odsay_client, "is_enabled", None)
        return bool(enabled()) if callable(enabled) else bool(getattr(self._odsay_client, "enabled", False))


def _local_fallback_response(
    response: RoutePlanResponse,
    *,
    warning: str,
    error: Exception | None = None,
) -> RoutePlanResponse:
    evidence: dict[str, Any] = {"provider": "ODSAY", "fallback": "LOCAL_FALLBACK"}
    if error is not None:
        evidence["errorType"] = type(error).__name__
    return response.model_copy(
        update={
            "warnings": _dedupe([*response.warnings, warning]),
            "rawProviderEvidence": evidence,
        }
    )


def _dedupe_candidates(candidates: list[RoutePlanCandidate]) -> list[RoutePlanCandidate]:
    seen: set[tuple] = set()
    out: list[RoutePlanCandidate] = []
    for candidate in candidates:
        signature = tuple(
            (segment.routeNo, segment.routeId, segment.boardStop.stopId, segment.alightStop.stopId)
            for segment in candidate.segments
        )
        if signature in seen:
            continue
        seen.add(signature)
        out.append(candidate)
    return out


def _dedupe(values: list[str]) -> list[str]:
    return list(dict.fromkeys(values))


def _strongest_source(sources: list[FallbackSource]) -> FallbackSource:
    priority = {
        FallbackSource.PUBLIC_API: 4,
        FallbackSource.CACHE: 3,
        FallbackSource.GEMINI: 2,
        FallbackSource.MOCK: 1,
        FallbackSource.ERROR: 0,
    }
    return max(sources, key=lambda source: priority[source], default=FallbackSource.ERROR)
