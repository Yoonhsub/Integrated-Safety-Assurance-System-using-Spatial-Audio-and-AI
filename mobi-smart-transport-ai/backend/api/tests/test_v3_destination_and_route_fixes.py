"""목적지 후보 랭킹·정규화 및 경로 주행시간/정류장수 회귀 테스트.

스크린샷 기반 실버그 재발 방지:
- "청주대학교"가 정류장명 "청주대학교.뉴시스"로 잡혀 되묻던 문제
- "청주대"가 "청주대왕약국" 같은 상호명이나 "충북대학교" 추론에 밀리던 문제
- "충북대학교"가 "충북대학교병원" 부분일치에 밀려 NEEDS_CHOICE로 빠지던 문제
- "터미널"이 "새터미널약국/터미널꽃집" 상호에 밀려 오확정되던 문제
- 경로 세그먼트가 "58개 정류장인데 2분 탑승"으로 표시되던 모순
"""
from __future__ import annotations

import app.services.destination_candidate_resolver as resolver_mod
from app.services.destination_candidate_resolver import (
    DestinationCandidateResolver,
    KakaoLocalSearchProvider,
)
from app.services.v3_agent_tools import verify_route_tool
from app.schemas.v3 import (
    DestinationCandidate,
    DestinationCandidateType,
    DestinationResolveResponse,
    DestinationResolveStatus,
    RoutePlanCandidate,
    RoutePlanResponse,
    RoutePlanSegment,
    RoutePlanStatus,
    RoutePlanStop,
    RoutePlanType,
    V3BusArrival,
    FallbackSource,
)

CLAT = resolver_mod._CHEONGJU_CENTER_LAT
CLNG = resolver_mod._CHEONGJU_CENTER_LNG


class _FakeResp:
    def __init__(self, docs):
        self._docs = docs

    def raise_for_status(self):
        return None

    def json(self):
        return {"documents": self._docs}


class _FakeClient:
    def __init__(self, names):
        self._docs = [
            {
                "place_name": n,
                "x": str(CLNG),
                "y": str(CLAT),
                "road_address_name": "충북 청주시",
                "address_name": "충북 청주시",
            }
            for n in names
        ]

    def get(self, url, params=None, headers=None):
        return _FakeResp(self._docs)


def _search(names, query, monkeypatch):
    monkeypatch.setenv("KAKAO_REST_API_KEY", "dummy")
    monkeypatch.setenv("KAKAO_LOCAL_SEARCH_ENABLED", "true")
    provider = KakaoLocalSearchProvider(client=_FakeClient(names))
    return provider.search(query, origin_lat=CLAT, origin_lng=CLNG, limit=5)


def test_kakao_dotted_campus_name_collapses_to_prefix(monkeypatch):
    """카카오 "단지.건물"(청주대학교.뉴시스)은 단지명으로 정규화되어 정확일치로 확정된다."""
    results = _search(["청주대학교.뉴시스", "청주대학교"], "청주대학교", monkeypatch)
    assert results, "카카오 후보가 비어 있으면 안 된다"
    assert all(c.name == "청주대학교" for c in results)
    assert any(c.confidence >= 0.99 for c in results)


def test_kakao_exact_beats_prefix_match(monkeypatch):
    """정확일치(충북대학교 0.99)가 접두일치(충북대학교병원 0.94)보다 높아야 한다."""
    results = _search(["충북대학교병원", "충북대학교"], "충북대학교", monkeypatch)
    by_name = {c.name: c.confidence for c in results}
    assert by_name["충북대학교"] == 0.99
    assert by_name["충북대학교병원"] == 0.94
    assert by_name["충북대학교"] > by_name["충북대학교병원"]


def test_kakao_midword_business_match_is_demoted(monkeypatch):
    """검색어가 상호 중간/끝에 낀 약한 일치(새터미널약국)는 낮은 신뢰도(0.85)여야 한다."""
    results = _search(["새터미널약국"], "터미널", monkeypatch)
    assert results
    assert all(c.confidence <= 0.85 for c in results)


def test_transit_hub_term_returns_only_known_terminals():
    """'터미널'은 상호명이 아니라 알려진 고속/시외 터미널만 후보로 올린다."""
    candidates = DestinationCandidateResolver()._build_candidates(
        "터미널", normalized="터미널", origin_lat=None, origin_lng=None, live=False
    )
    names = {c.name for c in candidates}
    assert names == {"청주고속버스터미널", "청주시외버스터미널"}


class _EmptyStopCatalog:
    def search_by_name(self, **_):
        return []

    def find_nearby(self, **_):
        return []


class _MisleadingCheongjuUniversitySearch:
    def search(self, query, *_, **__):
        if query == "청주대":
            return [
                DestinationCandidate(
                    name="청주대왕약국",
                    type=DestinationCandidateType.PLACE,
                    confidence=0.94,
                    latitude=CLAT,
                    longitude=CLNG,
                    source=FallbackSource.PUBLIC_API,
                )
            ]
        return [
            DestinationCandidate(
                name="충북대학교",
                type=DestinationCandidateType.PLACE,
                confidence=0.95,
                latitude=CLAT,
                longitude=CLNG,
                source=FallbackSource.PUBLIC_API,
            )
        ]


def test_cheongju_university_alias_beats_misleading_business_candidate():
    """'청주대'는 승인된 청주대학교 별칭으로 확정하고 약국 상호명으로 되묻지 않는다."""
    resolver = DestinationCandidateResolver(
        stop_catalog=_EmptyStopCatalog(),
        local_search=_MisleadingCheongjuUniversitySearch(),
    )

    result = resolver.resolve(heard_text="청주대", live=True)

    assert result.status == DestinationResolveStatus.RESOLVED
    assert result.topCandidate is not None
    assert result.topCandidate.name == "청주대학교"
    assert result.question is None


def test_cheongju_university_exact_name_beats_chungbuk_university_candidate():
    """'청주대학교'는 비슷한 대학명 후보가 있어도 청주대학교로 확정한다."""
    resolver = DestinationCandidateResolver(
        stop_catalog=_EmptyStopCatalog(),
        local_search=_MisleadingCheongjuUniversitySearch(),
    )

    result = resolver.resolve(heard_text="청주대학교", live=True)

    assert result.status == DestinationResolveStatus.RESOLVED
    assert result.topCandidate is not None
    assert result.topCandidate.name == "청주대학교"
    assert result.question is None


def _stop(stop_id: str, name: str) -> RoutePlanStop:
    return RoutePlanStop(stopId=stop_id, stopName=name, latitude=CLAT, longitude=CLNG)


def test_verify_route_tool_preserves_ride_time():
    """verify_route_tool은 주행시간(estimatedMinutes)을 도착 카운트다운으로 덮어쓰지 않는다.

    과거: 58개 정류장 구간(주행 ~45분)이 '다음 버스 2분 뒤 도착' 때문에 2분으로 표시됨.
    """
    segment = RoutePlanSegment(
        routeNo="823",
        routeId="route-823",
        boardStop=_stop("S1", "충북대학교후문"),
        alightStop=_stop("S2", "용암서희스타힐스아파트"),
        stopCount=58,
        estimatedMinutes=45,  # ODsay sectionTime(주행시간)
        arrivals=[
            V3BusArrival(
                routeId="route-823",
                routeNo="823",
                stopId="S1",
                arrivalMinutes=2,  # 다음 버스 도착까지(주행시간이 아님)
                remainingStops=1,
            )
        ],
        arrivalSource=FallbackSource.PUBLIC_API,
    )
    candidate = RoutePlanCandidate(
        planId="p1",
        type=RoutePlanType.DIRECT,
        destinationName="상당구청",
        summary="테스트 경로",
        boardingInstruction="충북대학교후문에서 823번 탑승",
        transferCount=0,
        totalBusStopCount=58,
        estimatedWalkMeters=0.0,
        accessibilityScore=0.0,
        simplicityScore=1.0,
        score=50.0,
        segments=[segment],
    )
    plan = RoutePlanResponse(
        status=RoutePlanStatus.RESOLVED,
        heardText="상당구청",
        destination=DestinationResolveResponse(
            status=DestinationResolveStatus.RESOLVED,
            heardText="상당구청",
            normalizedText="상당구청",
        ),
        recommendedPlan=candidate,
    )

    verified = verify_route_tool(plan)
    seg = verified.recommendedPlan.segments[0]
    assert seg.estimatedMinutes == 45, "주행시간이 도착 카운트다운(2분)으로 덮어써지면 안 된다"
    assert seg.stopCount == 58
