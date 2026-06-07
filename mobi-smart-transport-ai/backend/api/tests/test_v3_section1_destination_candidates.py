from datetime import datetime, timezone

from fastapi.testclient import TestClient

from app.main import app
from app.schemas.v3 import DestinationCandidate, DestinationCandidateType, FallbackSource
from app.services.cheongju_bus_stops_service import CheongjuBusStopMatch
from app.services.destination_candidate_resolver import DestinationCandidateResolver, KakaoLocalSearchProvider

client = TestClient(app)


def test_destination_candidates_resolves_place_to_coordinates_and_nearby_stops() -> None:
    response = client.get(
        "/bus/destination-candidates",
        params={"q": "상당산성 가고 싶어", "originLat": 36.6359, "originLng": 127.4596, "mode": "mock"},
    )

    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "RESOLVED"
    assert body["topCandidate"]["name"] == "상당산성"
    assert body["topCandidate"]["type"] == "PLACE"
    assert body["topCandidate"]["latitude"] is not None
    assert body["topCandidate"]["longitude"] is not None
    assert body["destinationStops"]
    assert body["destinationStops"][0]["directionHint"].endswith("방향")
    assert body["destinationStops"][0]["sideHint"] is None
    assert body["destinationStops"][0]["visionRequiredForSideHint"] is False
    assert body["originStops"][0]["stopName"] == "사창사거리 정류장"


def test_destination_candidates_needs_confirmation_for_stt_like_misrecognition() -> None:
    response = client.get("/bus/destination-candidates", params={"q": "상단산성", "mode": "mock"})

    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "NEEDS_CONFIRMATION"
    assert body["topCandidate"]["name"] == "상당산성"
    assert body["question"] == "혹시 상당산성 맞을까요?"


def test_destination_candidates_confirms_sachang_stt_misrecognition() -> None:
    result = DestinationCandidateResolver().resolve(heard_text="산창사거리", live=False)

    assert result.status == "NEEDS_CONFIRMATION"
    assert result.topCandidate is not None
    assert result.topCandidate.name == "사창사거리"
    assert result.question == "혹시 사창사거리 맞을까요?"


def test_destination_candidates_auto_resolves_obvious_hospital_alias() -> None:
    result = DestinationCandidateResolver().resolve(heard_text="충북 대학교 병원", live=False)

    assert result.status == "RESOLVED"
    assert result.topCandidate is not None
    assert result.topCandidate.name == "충북대학교병원"
    assert result.question is None


def test_destination_resolver_prefers_stt_confirmation_over_live_keyword_choice() -> None:
    class EmptyStopCatalog:
        def search_by_name(self, **_):
            return []

        def find_nearby(self, **_):
            return []

    class LiveLocalSearch:
        def search(self, query, *_, **__):
            if query == "상당산성":
                return [
                    DestinationCandidate(
                        name="상당산성",
                        type=DestinationCandidateType.PLACE,
                        confidence=0.91,
                        latitude=36.6610,
                        longitude=127.5349,
                        source=FallbackSource.PUBLIC_API,
                    )
                ]
            return [
                DestinationCandidate(
                    name="상단산성 한옥마을 주차장",
                    type=DestinationCandidateType.PLACE,
                    confidence=0.90,
                    latitude=36.6610,
                    longitude=127.5349,
                    source=FallbackSource.PUBLIC_API,
                )
            ]

    resolver = DestinationCandidateResolver(
        stop_catalog=EmptyStopCatalog(),
        local_search=LiveLocalSearch(),
    )
    result = resolver.resolve(heard_text="상단산성", live=True)

    assert result.status == "NEEDS_CONFIRMATION"
    assert result.topCandidate is not None
    assert result.topCandidate.name == "상당산성"
    assert result.question == "혹시 상당산성 맞을까요?"


def test_destination_resolver_verifies_cheongju_typo_before_confirmation() -> None:
    class EmptyLocalSearch:
        def search(self, *_, **__):
            return []

    class SachangStopCatalog:
        def search_by_name(self, *, stop_name: str, limit: int = 5):
            if stop_name != "사창사거리":
                return []
            return [
                CheongjuBusStopMatch(
                    service_id="1933",
                    stop_name="사창사거리",
                    longitude=127.4596675,
                    latitude=36.63594787,
                    endpoint="https://api.odcloud.kr/api/example",
                    fetched_at=datetime(2026, 6, 1, tzinfo=timezone.utc),
                    total_count=3402,
                )
            ]

        def find_nearby(self, **_):
            return self.search_by_name(stop_name="사창사거리")

    resolver = DestinationCandidateResolver(
        stop_catalog=SachangStopCatalog(),
        local_search=EmptyLocalSearch(),
    )
    result = resolver.resolve(heard_text="사당사거리", live=True)

    assert result.status == "NEEDS_CONFIRMATION"
    assert result.topCandidate is not None
    assert result.topCandidate.name == "사창사거리"
    assert result.topCandidate.source == "PUBLIC_API"
    assert result.question == "혹시 사창사거리 맞을까요?"


def test_destination_resolver_does_not_suggest_unverified_cheongju_typo() -> None:
    class EmptyProvider:
        def search_by_name(self, **_):
            return []

        def find_nearby(self, **_):
            return []

        def search(self, *_, **__):
            return []

    provider = EmptyProvider()
    resolver = DestinationCandidateResolver(stop_catalog=provider, local_search=provider)
    result = resolver.resolve(heard_text="사당사거리", live=True)

    assert result.status == "NOT_FOUND"
    assert result.topCandidate is None


def test_destination_candidates_needs_choice_for_ambiguous_terminal() -> None:
    response = client.get("/bus/destination-candidates", params={"q": "터미널", "mode": "mock"})

    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "NEEDS_CHOICE"
    names = [item["name"] for item in body["candidates"]]
    assert "청주고속버스터미널" in names
    assert "청주시외버스터미널" in names


def test_destination_candidates_resolves_exact_terminal_names() -> None:
    for query in ("청주고속버스터미널", "청주시외버스터미널"):
        response = client.get("/bus/destination-candidates", params={"q": query, "mode": "mock"})

        assert response.status_code == 200
        body = response.json()
        assert body["status"] == "RESOLVED"
        assert body["topCandidate"]["name"] == query


def test_destination_candidates_unknown_destination_is_not_found() -> None:
    response = client.get("/bus/destination-candidates", params={"q": "존재하지 않는 목적지", "mode": "mock"})

    assert response.status_code == 200
    assert response.json()["status"] == "NOT_FOUND"


def test_destination_resolver_uses_public_stop_catalog_when_live() -> None:
    class EmptyLocalSearch:
        def search(self, *_, **__):
            return []

    class FakeStopCatalog:
        def search_by_name(self, *, stop_name: str, limit: int = 5):
            return [
                CheongjuBusStopMatch(
                    service_id="1933",
                    stop_name="청주체육관",
                    longitude=127.474,
                    latitude=36.637,
                    endpoint="https://api.odcloud.kr/api/example",
                    fetched_at=datetime(2026, 6, 1, tzinfo=timezone.utc),
                    total_count=3402,
                    distance_meters=None,
                )
            ]

        def find_nearby(self, *, origin_lat: float, origin_lng: float, limit: int = 5, radius_meters: float = 1000.0):
            return [
                CheongjuBusStopMatch(
                    service_id="1933",
                    stop_name="청주체육관",
                    longitude=127.474,
                    latitude=36.637,
                    endpoint="https://api.odcloud.kr/api/example",
                    fetched_at=datetime(2026, 6, 1, tzinfo=timezone.utc),
                    total_count=3402,
                    distance_meters=42.0,
                )
            ]

    resolver = DestinationCandidateResolver(stop_catalog=FakeStopCatalog(), local_search=EmptyLocalSearch())
    result = resolver.resolve(heard_text="청주체육관", origin_lat=36.6371, origin_lng=127.4741, live=True)

    assert result.status == "RESOLVED"
    assert result.topCandidate is not None
    assert result.topCandidate.type == "STOP"
    assert result.topCandidate.stopId == "1933"
    assert result.topCandidate.source == "PUBLIC_API"
    assert result.destinationStops[0].source == "PUBLIC_API"
    assert result.destinationStops[0].distanceMeters == 42.0


def test_destination_resolver_does_not_resolve_candidate_without_coordinates() -> None:
    class EmptyStopCatalog:
        def search_by_name(self, **_):
            return []

        def find_nearby(self, **_):
            return []

    class CoordinateMissingLocalSearch:
        def search(self, *_, **__):
            return [
                DestinationCandidate(
                    name="좌표없는장소",
                    type=DestinationCandidateType.PLACE,
                    confidence=0.95,
                    source=FallbackSource.PUBLIC_API,
                )
            ]

    resolver = DestinationCandidateResolver(
        stop_catalog=EmptyStopCatalog(),
        local_search=CoordinateMissingLocalSearch(),
    )
    result = resolver.resolve(heard_text="좌표없는장소", live=True)

    assert result.status == "NOT_FOUND"
    assert result.question is not None
    assert "위치 좌표" in result.question


def test_destination_resolver_does_not_resolve_candidate_without_nearby_stops() -> None:
    class EmptyStopCatalog:
        def search_by_name(self, **_):
            return []

        def find_nearby(self, **_):
            return []

    class IsolatedLocalSearch:
        def search(self, *_, **__):
            return [
                DestinationCandidate(
                    name="외딴장소",
                    type=DestinationCandidateType.PLACE,
                    confidence=0.95,
                    latitude=0.0,
                    longitude=0.0,
                    source=FallbackSource.PUBLIC_API,
                )
            ]

    resolver = DestinationCandidateResolver(
        stop_catalog=EmptyStopCatalog(),
        local_search=IsolatedLocalSearch(),
    )
    result = resolver.resolve(heard_text="외딴장소", live=True)

    assert result.status == "NOT_FOUND"
    assert result.question is not None
    assert "하차 정류장" in result.question


def test_arrivals_mode_parameter_overrides_global_live_setting(monkeypatch) -> None:
    monkeypatch.setenv("PUBLIC_DATA_USE_MOCK", "false")
    monkeypatch.delenv("PUBLIC_DATA_API_KEY", raising=False)

    response = client.get(
        "/bus/arrivals",
        params={"stopId": "mock-stop-001", "routeNo": "502", "mode": "mock"},
    )

    assert response.status_code == 200
    body = response.json()
    assert body["fallbackSource"] == "MOCK"
    assert body["arrivals"][0]["busId"] == "BUS_2"


def test_destination_candidates_rejects_partial_origin_coordinates() -> None:
    response = client.get(
        "/bus/destination-candidates",
        params={"q": "상당산성", "originLat": 36.6359, "mode": "mock"},
    )

    assert response.status_code == 422
    assert response.json()["error"]["code"] == "INVALID_ORIGIN"


def test_destination_candidates_rejects_unknown_mode() -> None:
    response = client.get("/bus/destination-candidates", params={"q": "상당산성", "mode": "preview"})

    assert response.status_code == 422


def test_kakao_local_search_limits_keyword_results_to_cheongju_area(monkeypatch) -> None:
    class FakeResponse:
        def raise_for_status(self):
            return None

        def json(self):
            return {
                "documents": [
                    {"place_name": "검색어와 무관한 가까운 매장", "x": "127.488", "y": "36.641"},
                    {"place_name": "청주성안길점", "x": "127.489", "y": "36.642"},
                    {"place_name": "안산 성안길", "x": "126.85", "y": "37.30"},
                ]
            }

    class FakeHttpClient:
        def __init__(self):
            self.params = None

        def get(self, _url, *, params, headers):
            self.params = params
            return FakeResponse()

    monkeypatch.setenv("KAKAO_LOCAL_SEARCH_ENABLED", "true")
    monkeypatch.setenv("KAKAO_REST_API_KEY", "test-key")
    http = FakeHttpClient()

    candidates = KakaoLocalSearchProvider(client=http).search("성안길", limit=5)

    assert [candidate.name for candidate in candidates] == ["성안길"]
    assert candidates[0].source == "PUBLIC_API"
    assert http.params["sort"] == "distance"
    assert http.params["radius"] == 20_000


def test_kakao_local_search_rejects_out_of_area_address_results(monkeypatch) -> None:
    class FakeResponse:
        def raise_for_status(self):
            return None

        def json(self):
            return {
                "documents": [
                    {"address_name": "경기 안산시 상록구 성안길", "x": "126.85", "y": "37.30"},
                ]
            }

    class FakeHttpClient:
        def get(self, url, *, params, headers):
            if url.endswith("/address.json"):
                return FakeResponse()
            return type("EmptyResponse", (), {"raise_for_status": lambda self: None, "json": lambda self: {"documents": []}})()

    monkeypatch.setenv("KAKAO_LOCAL_SEARCH_ENABLED", "true")
    monkeypatch.setenv("KAKAO_REST_API_KEY", "test-key")

    candidates = KakaoLocalSearchProvider(client=FakeHttpClient()).search("성안길", limit=5)

    assert candidates == []
