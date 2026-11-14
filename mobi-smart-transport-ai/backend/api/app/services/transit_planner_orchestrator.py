from __future__ import annotations

import os
from concurrent.futures import ThreadPoolExecutor, wait
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

_SHARED_ROUTE_SERVICE = BusRouteService()
_SHARED_LOCAL_SEQUENCE_CACHE = RouteStopSequenceCache(
    route_service=_SHARED_ROUTE_SERVICE,
    mock_sequences=_mock_route_sequences(),
)
_SHARED_ENRICHMENT_SEQUENCE_CACHE = RouteStopSequenceCache(
    route_service=_SHARED_ROUTE_SERVICE,
    mock_sequences=_mock_route_sequences(),
)
_ENRICHMENT_EXECUTOR = ThreadPoolExecutor(max_workers=4, thread_name_prefix="tago-enrich")


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
        local_sequence_cache: RouteStopSequenceCache | None = None,
        enrichment_sequence_cache: RouteStopSequenceCache | None = None,
    ) -> None:
        self._resolver = resolver or DestinationCandidateResolver()
        using_shared_route_service = route_service is None
        self._route_service = route_service or _SHARED_ROUTE_SERVICE
        self._arrival_fetcher = arrival_fetcher
        local_sequence_cache = local_sequence_cache or (
            _SHARED_LOCAL_SEQUENCE_CACHE
            if using_shared_route_service
            else RouteStopSequenceCache(
                route_service=self._route_service,
                mock_sequences=_mock_route_sequences(),
            )
        )
        self._local_planner = CheongjuRoutePlanner(
            resolver=self._resolver,
            route_service=self._route_service,
            arrival_fetcher=arrival_fetcher,
            sequence_cache=local_sequence_cache,
        )
        self._odsay_client = odsay_client or OdsayClient()
        self._odsay_mapper = odsay_mapper or OdsayRouteMapper()
        self._enricher = enricher or RoutePlanEnricher(
            sequence_cache=enrichment_sequence_cache
            or (
                _SHARED_ENRICHMENT_SEQUENCE_CACHE
                if using_shared_route_service
                else RouteStopSequenceCache(
                    route_service=self._route_service,
                    mock_sequences=_mock_route_sequences(),
                )
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
        from app.services.vision_binding_service import vision_binding_service
        if live and vision_binding_service.has_camera_reservation():
            destination = self._resolver.resolve(heard_text=heard_text, origin_lat=origin_lat,
                                                 origin_lng=origin_lng, live=live)
            # Stop-cache readiness alone does not prove that sequence/arrival
            # enrichment can finish without I/O. Defer new route search entirely.
            return self._local_planner._empty_response(
                status=RoutePlanStatus.NOT_FOUND, destination=destination.model_copy(update={"fallbackSource": FallbackSource.ERROR}),
                heard_text=heard_text,
                question="카메라 사용 중에는 새 경로 검색을 보류합니다. 카메라를 종료한 뒤 다시 검색해 주세요.")
        use_odsay = live and self._odsay_enabled()
        local_response = self._local_planner.plan(
            heard_text=heard_text,
            origin_lat=origin_lat,
            origin_lng=origin_lng,
            live=live,
            # ODsay is the primary route provider when enabled. Avoid loading
            # every TAGO route unless we actually need a local fallback; live
            # fallback calls below still prohibit demo sequences.
            use_live_sequences=live and not use_odsay,
        )
        if not use_odsay:
            return local_response
        if (
            local_response.destination.status != DestinationResolveStatus.RESOLVED
            or origin_lat is None
            or origin_lng is None
            or local_response.destination.topCandidate is None
            or local_response.destination.topCandidate.latitude is None
            or local_response.destination.topCandidate.longitude is None
        ):
            return self._local_planner.plan(
                heard_text=heard_text,
                origin_lat=origin_lat,
                origin_lng=origin_lng,
                live=live,
                use_live_sequences=live,
            )

        destination = local_response.destination.topCandidate
        try:
            result = self._odsay_client.search_public_transit_path(
                origin_lat=origin_lat,
                origin_lng=origin_lng,
                destination_lat=destination.latitude,
                destination_lng=destination.longitude,
            )
            mapped = self._odsay_mapper.map_result(result, destination_name=destination.name)
            enrich_limit = _max_sync_enrich_candidates()
            enriched, enrichment_timed_out = self._enrich_with_deadline(
                mapped[:enrich_limit],
                live=live,
            )
        except OdsayUnavailableError as exc:
            fallback = self._live_local_fallback(heard_text, origin_lat, origin_lng, live=live)
            return _local_fallback_response(fallback, warning="ODsay unavailable; local planner fallback used", error=exc)
        except Exception as exc:
            fallback = self._live_local_fallback(heard_text, origin_lat, origin_lng, live=live)
            return _local_fallback_response(fallback, warning="ODsay unavailable; local planner fallback used", error=exc)

        if not mapped:
            fallback = self._live_local_fallback(heard_text, origin_lat, origin_lng, live=live)
            return _local_fallback_response(
                fallback,
                warning="ODsay returned no usable bus candidates; local planner fallback used",
            )

        # Keep ODsay alternatives visible, but enrich only the first candidates
        # synchronously so the verified primary guidance is ready quickly.
        candidates = _dedupe_candidates([*enriched, *mapped[len(enriched) :]])
        if enrichment_timed_out:
            candidates = [
                _with_warning(
                    candidate,
                    "TAGO 실시간 보강이 지연되어 ODsay 경로를 먼저 안내함",
                )
                for candidate in candidates
            ]
        plans = self._ranker.rank(candidates)[:5]
        recommended = plans[0] if plans else None
        warnings = _dedupe(recommended.warnings if recommended else [])
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
            fallbackSource=_strongest_source([destination.source, *(plan.fallbackSource for plan in plans)]),
            warnings=warnings,
            rawProviderEvidence={
                "provider": "ODSAY",
                "odsayCandidates": len(mapped),
                "tagoEnrichedCandidates": len(enriched),
                "tagoEnrichmentTimedOut": enrichment_timed_out,
                "localCandidates": len(local_response.plans),
            },
        )

    def _odsay_enabled(self) -> bool:
        enabled = getattr(self._odsay_client, "is_enabled", None)
        return bool(enabled()) if callable(enabled) else bool(getattr(self._odsay_client, "enabled", False))

    def _live_local_fallback(
        self,
        heard_text: str,
        origin_lat: float | None,
        origin_lng: float | None,
        *,
        live: bool,
    ) -> RoutePlanResponse:
        return self._local_planner.plan(
            heard_text=heard_text,
            origin_lat=origin_lat,
            origin_lng=origin_lng,
            live=live,
            use_live_sequences=live,
        )

    def _enrich_with_deadline(
        self,
        candidates: list[RoutePlanCandidate],
        *,
        live: bool,
    ) -> tuple[list[RoutePlanCandidate], bool]:
        futures = [
            (candidate, _ENRICHMENT_EXECUTOR.submit(self._enricher.enrich, candidate, live=live))
            for candidate in candidates
        ]
        if not futures:
            return [], False
        done, not_done = wait(
            [future for _, future in futures],
            timeout=_sync_enrich_timeout_seconds(),
        )
        enriched = [
            future.result() if future in done else candidate
            for candidate, future in futures
        ]
        return enriched, bool(not_done)


def _max_sync_enrich_candidates() -> int:
    try:
        value = int(os.getenv("ODSAY_MAX_SYNC_ENRICH_CANDIDATES", "2"))
    except ValueError:
        value = 2
    return max(0, min(value, 5))


def _sync_enrich_timeout_seconds() -> float:
    try:
        value = float(os.getenv("ODSAY_SYNC_ENRICH_TIMEOUT_SECONDS", "20.0"))
    except ValueError:
        value = 20.0
    return max(0.05, min(value, 30.0))


def _with_warning(candidate: RoutePlanCandidate, warning: str) -> RoutePlanCandidate:
    return candidate.model_copy(update={"warnings": _dedupe([*candidate.warnings, warning])})


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
            "rawProviderEvidence": {**response.rawProviderEvidence, **evidence},
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
