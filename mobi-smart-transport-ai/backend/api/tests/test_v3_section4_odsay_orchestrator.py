from __future__ import annotations

import time
from typing import Any

from app.schemas.v3 import (
    DestinationCandidate,
    DestinationCandidateType,
    DestinationResolveResponse,
    DestinationResolveStatus,
    FallbackSource,
    NearbyStopCandidate,
    RoutePlanCandidate,
    RoutePlanReadiness,
    RoutePlanResponse,
    RoutePlanSegment,
    RoutePlanSource,
    RoutePlanStatus,
    RoutePlanStop,
    RoutePlanType,
    RoutePlanVerificationStatus,
    V3BusArrival,
    V3BusArrivalsResponse,
)
from app.services.odsay_client import OdsayClient, OdsayTransitResult, OdsayUnavailableError
from app.services.odsay_route_mapper import OdsayRouteMapper
from app.services.route_plan_enricher import RoutePlanEnricher
from app.services.route_ranker import RouteRanker
from app.services.route_stop_sequence_cache import RouteSequence, RouteStopNode, RouteStopSequenceCache
from app.services.transit_planner_orchestrator import (
    TransitPlannerOrchestrator,
    _max_sync_enrich_candidates,
    _sync_enrich_timeout_seconds,
)


def test_odsay_client_keeps_longitude_in_x_and_latitude_in_y(monkeypatch) -> None:
    monkeypatch.setenv("ODSAY_ENABLED", "true")
    monkeypatch.setenv("ODSAY_API_KEY", "secret-for-test")
    fake_http = _FakeHttpClient({"result": {"path": []}})

    OdsayClient(client=fake_http).search_public_transit_path(
        origin_lat=36.1,
        origin_lng=127.1,
        destination_lat=36.2,
        destination_lng=127.2,
    )

    assert fake_http.params == {
        "SX": 127.1,
        "SY": 36.1,
        "EX": 127.2,
        "EY": 36.2,
        "SearchType": 0,
        "SearchPathType": 2,
        "output": "json",
        "apiKey": "secret-for-test",
    }


def test_orchestrator_keeps_local_planner_when_odsay_is_disabled() -> None:
    local = _local_response()
    orchestrator = _orchestrator(local_response=local, odsay_client=_FakeOdsayClient(enabled=False))

    response = orchestrator.plan(heard_text="상당산성", origin_lat=36.1, origin_lng=127.1, live=True)

    assert response is local
    assert response.recommendedPlan.planSource == RoutePlanSource.LOCAL_FALLBACK


def test_odsay_success_and_tago_match_returns_enriched_candidate() -> None:
    enricher = RoutePlanEnricher(
        sequence_cache=RouteStopSequenceCache(mock_sequences=[_sequence()]),
        arrival_fetcher=_arrival_fetcher,
    )
    orchestrator = _orchestrator(
        local_response=_local_response(plans=[]),
        odsay_client=_FakeOdsayClient(),
        enricher=enricher,
    )

    response = orchestrator.plan(heard_text="상당산성", origin_lat=36.1, origin_lng=127.1, live=True)

    plan = response.recommendedPlan
    assert plan is not None
    assert plan.planSource == RoutePlanSource.ODSAY_ENRICHED
    assert plan.verificationStatus == RoutePlanVerificationStatus.VERIFIED_WITH_TAGO
    assert plan.segments[0].routeId == "CJB-862"
    assert plan.segments[0].boardingStopNodeId == "CJB-BOARD"
    assert plan.segments[0].directionHint == "청주체육관 정류장·상당산성 정류장 방향"
    assert plan.arrival is not None
    assert plan.arrival.source == FallbackSource.PUBLIC_API


def test_odsay_stop_name_suffix_still_matches_tago_sequence() -> None:
    enricher = RoutePlanEnricher(
        sequence_cache=RouteStopSequenceCache(mock_sequences=[_sequence()]),
        arrival_fetcher=_arrival_fetcher,
    )
    orchestrator = _orchestrator(
        local_response=_local_response(plans=[]),
        odsay_client=_FakeOdsayClient(
            payload=_odsay_payload(
                boarding_name="사창사거리앞",
                alighting_name="상당산성입구",
            )
        ),
        enricher=enricher,
    )

    response = orchestrator.plan(heard_text="상당산성", origin_lat=36.1, origin_lng=127.1, live=True)

    plan = response.recommendedPlan
    assert plan is not None
    assert plan.verificationStatus == RoutePlanVerificationStatus.VERIFIED_WITH_TAGO
    assert plan.segments[0].boardStop.stopId == "CJB-BOARD"
    assert plan.segments[0].alightStop.stopId == "CJB-ALIGHT"


def test_odsay_success_without_tago_match_keeps_safe_odsay_only_candidate() -> None:
    orchestrator = _orchestrator(
        local_response=_local_response(plans=[]),
        odsay_client=_FakeOdsayClient(),
        enricher=RoutePlanEnricher(sequence_cache=RouteStopSequenceCache()),
    )

    response = orchestrator.plan(heard_text="상당산성", origin_lat=36.1, origin_lng=127.1, live=True)

    plan = response.recommendedPlan
    assert plan is not None
    assert plan.planSource == RoutePlanSource.ODSAY
    assert plan.verificationStatus == RoutePlanVerificationStatus.ODSAY_ONLY
    assert plan.arrival is None
    assert any("매칭 실패" in warning for warning in plan.warnings)
    assert "실시간 도착정보" in plan.boardingInstruction


def test_live_odsay_candidate_does_not_treat_mock_sequence_as_tago_verification() -> None:
    mock_sequence = RouteSequence(
        route_no="862",
        route_id="mock-route-862",
        nodes=_sequence().nodes,
    )
    orchestrator = _orchestrator(
        local_response=_local_response(plans=[]),
        odsay_client=_FakeOdsayClient(),
        enricher=RoutePlanEnricher(sequence_cache=RouteStopSequenceCache(mock_sequences=[mock_sequence])),
    )

    response = orchestrator.plan(heard_text="상당산성", origin_lat=36.1, origin_lng=127.1, live=True)

    assert response.recommendedPlan is not None
    assert response.recommendedPlan.verificationStatus == RoutePlanVerificationStatus.ODSAY_ONLY
    assert response.recommendedPlan.planSource == RoutePlanSource.ODSAY


def test_odsay_failure_records_local_fallback_evidence() -> None:
    response = _orchestrator(
        local_response=_local_response(),
        odsay_client=_FakeOdsayClient(error=OdsayUnavailableError("down")),
    ).plan(heard_text="상당산성", origin_lat=36.1, origin_lng=127.1, live=True)

    assert response.recommendedPlan is not None
    assert response.recommendedPlan.planSource == RoutePlanSource.LOCAL_FALLBACK
    assert "ODsay unavailable; local planner fallback used" in response.warnings
    assert response.rawProviderEvidence["fallback"] == "LOCAL_FALLBACK"


def test_ranker_prefers_verified_local_candidate_over_unverified_odsay_candidate() -> None:
    local = _candidate(plan_id="local", verification=RoutePlanVerificationStatus.LOCAL_ONLY)
    odsay = _candidate(
        plan_id="odsay",
        verification=RoutePlanVerificationStatus.ODSAY_ONLY,
        plan_source=RoutePlanSource.ODSAY,
    )

    ranked = RouteRanker().rank([odsay, local])

    assert ranked[0].planId == "local"


def test_odsay_messages_do_not_add_side_of_road_claims() -> None:
    response = _orchestrator(
        local_response=_local_response(plans=[]),
        odsay_client=_FakeOdsayClient(),
        enricher=RoutePlanEnricher(sequence_cache=RouteStopSequenceCache()),
    ).plan(heard_text="상당산성", origin_lat=36.1, origin_lng=127.1, live=True)

    text = response.recommendedPlan.boardingInstruction
    for prohibited in ("건너편", "오른쪽", "왼쪽", "도로를 건너"):
        assert prohibited not in text


def test_sync_tago_enrichment_defaults_to_one_candidate_and_is_bounded(monkeypatch) -> None:
    monkeypatch.delenv("ODSAY_MAX_SYNC_ENRICH_CANDIDATES", raising=False)
    assert _max_sync_enrich_candidates() == 1

    monkeypatch.setenv("ODSAY_MAX_SYNC_ENRICH_CANDIDATES", "99")
    assert _max_sync_enrich_candidates() == 5

    monkeypatch.setenv("ODSAY_MAX_SYNC_ENRICH_CANDIDATES", "invalid")
    assert _max_sync_enrich_candidates() == 1


def test_slow_tago_enrichment_returns_odsay_candidate_without_blocking(monkeypatch) -> None:
    class SlowEnricher:
        def enrich(self, candidate, *, live):
            time.sleep(0.2)
            return candidate

    monkeypatch.setenv("ODSAY_SYNC_ENRICH_TIMEOUT_SECONDS", "0.05")
    orchestrator = _orchestrator(
        local_response=_local_response(plans=[]),
        odsay_client=_FakeOdsayClient(),
        enricher=SlowEnricher(),
    )

    started = time.perf_counter()
    response = orchestrator.plan(heard_text="상당산성", origin_lat=36.1, origin_lng=127.1, live=True)

    assert time.perf_counter() - started < 0.15
    assert response.recommendedPlan is not None
    assert response.recommendedPlan.verificationStatus == RoutePlanVerificationStatus.ODSAY_ONLY
    assert any("TAGO 실시간 보강이 지연" in warning for warning in response.warnings)


def test_sync_tago_enrichment_timeout_is_bounded(monkeypatch) -> None:
    monkeypatch.delenv("ODSAY_SYNC_ENRICH_TIMEOUT_SECONDS", raising=False)
    assert _sync_enrich_timeout_seconds() == 4.0

    monkeypatch.setenv("ODSAY_SYNC_ENRICH_TIMEOUT_SECONDS", "99")
    assert _sync_enrich_timeout_seconds() == 8.0


def test_odsay_mapper_removes_side_of_road_claims_from_provider_stop_names() -> None:
    candidate = OdsayRouteMapper().map_result(
        OdsayTransitResult(
            raw_response=_odsay_payload(
                boarding_name="건너편 사창사거리",
                alighting_name="도로를 건너 상당산성",
            )
        ),
        destination_name="상당산성",
    )[0]

    visible_text = " ".join(
        [
            candidate.boardingInstruction,
            candidate.segments[0].boardStop.stopName,
            candidate.segments[0].alightStop.stopName,
        ]
    )
    for prohibited in ("건너편", "오른쪽", "왼쪽", "도로를 건너"):
        assert prohibited not in visible_text


def test_odsay_mapper_preserves_tago_node_id_when_provider_supplies_it() -> None:
    candidate = OdsayRouteMapper().map_result(
        OdsayTransitResult(
            raw_response=_odsay_payload(
                start_id="CJB-BOARD",
                end_id="CJB-ALIGHT",
            )
        ),
        destination_name="상당산성",
    )[0]

    segment = candidate.segments[0]
    assert segment.boardStop.stopId == "CJB-BOARD"
    assert segment.boardStop.nodeId == "CJB-BOARD"
    assert segment.alightStop.stopId == "CJB-ALIGHT"
    assert segment.alightStop.nodeId == "CJB-ALIGHT"


class _FakeResponse:
    def __init__(self, payload: dict[str, Any]) -> None:
        self._payload = payload

    def raise_for_status(self) -> None:
        return None

    def json(self) -> dict[str, Any]:
        return self._payload


class _FakeHttpClient:
    def __init__(self, payload: dict[str, Any]) -> None:
        self.payload = payload
        self.params: dict[str, Any] = {}

    def get(self, url: str, *, params: dict[str, Any], headers=None) -> _FakeResponse:
        self.params = params
        return _FakeResponse(self.payload)


class _FakeOdsayClient:
    def __init__(
        self,
        *,
        enabled: bool = True,
        error: Exception | None = None,
        payload: dict[str, Any] | None = None,
    ) -> None:
        self.enabled = enabled
        self.error = error
        self.payload = payload

    def is_enabled(self) -> bool:
        return self.enabled

    def search_public_transit_path(self, **_: Any) -> OdsayTransitResult:
        if self.error:
            raise self.error
        return OdsayTransitResult(raw_response=self.payload or _odsay_payload())


class _FakeLocalPlanner:
    def __init__(self, response: RoutePlanResponse) -> None:
        self.response = response

    def plan(self, **_: Any) -> RoutePlanResponse:
        return self.response


def _orchestrator(
    *,
    local_response: RoutePlanResponse,
    odsay_client: _FakeOdsayClient,
    enricher: RoutePlanEnricher | None = None,
) -> TransitPlannerOrchestrator:
    orchestrator = TransitPlannerOrchestrator(odsay_client=odsay_client, enricher=enricher)
    orchestrator._local_planner = _FakeLocalPlanner(local_response)
    return orchestrator


def _local_response(*, plans: list[RoutePlanCandidate] | None = None) -> RoutePlanResponse:
    local_plans = [_candidate(plan_id="local")] if plans is None else plans
    recommended = local_plans[0] if local_plans else None
    return RoutePlanResponse(
        status=RoutePlanStatus.RESOLVED if recommended else RoutePlanStatus.NO_ROUTE,
        readiness=RoutePlanReadiness.READY if recommended else RoutePlanReadiness.NO_ROUTE,
        heardText="상당산성",
        destination=_destination(),
        plans=local_plans,
        recommendedPlan=recommended,
        alternatives=local_plans[1:],
        fallbackSource=FallbackSource.PUBLIC_API,
    )


def _destination() -> DestinationResolveResponse:
    return DestinationResolveResponse(
        status=DestinationResolveStatus.RESOLVED,
        heardText="상당산성",
        normalizedText="상당산성",
        topCandidate=DestinationCandidate(
            name="상당산성",
            type=DestinationCandidateType.PLACE,
            confidence=0.99,
            latitude=36.2,
            longitude=127.2,
        ),
        originStops=[NearbyStopCandidate(stopId="origin", stopName="사창사거리 정류장", latitude=36.1, longitude=127.1)],
        destinationStops=[NearbyStopCandidate(stopId="destination", stopName="상당산성 정류장", latitude=36.2, longitude=127.2)],
    )


def _candidate(
    *,
    plan_id: str,
    verification: RoutePlanVerificationStatus = RoutePlanVerificationStatus.LOCAL_ONLY,
    plan_source: RoutePlanSource = RoutePlanSource.LOCAL_FALLBACK,
) -> RoutePlanCandidate:
    return RoutePlanCandidate(
        planId=plan_id,
        type=RoutePlanType.DIRECT,
        destinationName="상당산성",
        summary="검증 경로",
        boardingInstruction="청주체육관·상당산성 방향 정류장에서 862번을 타면 돼.",
        transferCount=0,
        totalBusStopCount=2,
        estimatedWalkMeters=80,
        accessibilityScore=0,
        simplicityScore=0,
        score=0,
        segments=[_segment()],
        planSource=plan_source,
        verificationStatus=verification,
    )


def _segment() -> RoutePlanSegment:
    return RoutePlanSegment(
        routeNo="862",
        routeId="CJB-862",
        boardStop=RoutePlanStop(stopId="CJB-BOARD", stopName="사창사거리 정류장"),
        alightStop=RoutePlanStop(stopId="CJB-ALIGHT", stopName="상당산성 정류장"),
        stopCount=2,
        directionHint="청주체육관·상당산성 방향",
        arrivals=[
            V3BusArrival(
                routeNo="862",
                routeId="CJB-862",
                stopId="CJB-BOARD",
                arrivalMinutes=7,
                remainingStops=3,
            )
        ],
        arrivalSource=FallbackSource.PUBLIC_API,
    )


def _sequence() -> RouteSequence:
    return RouteSequence(
        route_no="862",
        route_id="CJB-862",
        source=FallbackSource.PUBLIC_API,
        nodes=(
            RouteStopNode("CJB-BOARD", "사창사거리 정류장", 1),
            RouteStopNode("CJB-MID", "청주체육관 정류장", 2),
            RouteStopNode("CJB-ALIGHT", "상당산성 정류장", 3),
        ),
    )


def _arrival_fetcher(stop_id: str, route_no: str, route_id: str) -> V3BusArrivalsResponse:
    return V3BusArrivalsResponse(
        stopId=stop_id,
        routeNo=route_no,
        arrivals=[
            V3BusArrival(
                routeNo=route_no,
                routeId=route_id,
                stopId=stop_id,
                arrivalMinutes=7,
                remainingStops=3,
            )
        ],
        fallbackSource=FallbackSource.PUBLIC_API,
    )


def _odsay_payload(
    *,
    boarding_name: str = "사창사거리",
    alighting_name: str = "상당산성",
    start_id: Any = 100,
    end_id: Any = 200,
) -> dict[str, Any]:
    return {
        "result": {
            "path": [
                {
                    "info": {"totalTime": 32, "busTransitCount": 0, "payment": 1500},
                    "subPath": [
                        {"trafficType": 3, "distance": 120, "sectionTime": 2},
                        {
                            "trafficType": 2,
                            "startName": boarding_name,
                            "startID": start_id,
                            "endName": alighting_name,
                            "endID": end_id,
                            "stationCount": 2,
                            "sectionTime": 22,
                            "lane": [{"busNo": "862", "busID": 86200}],
                        },
                    ],
                }
            ]
        }
    }
