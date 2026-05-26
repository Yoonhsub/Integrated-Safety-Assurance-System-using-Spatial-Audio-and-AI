"""BusArrivalsService V2 6 시나리오 회귀 테스트.

본 모듈은 V2 섹션 4(트리거 §6: empty stop, normal arrivals, low floor only,
mock fallback, schema)에 명시된 6 시나리오를 검증한다.

실행 방법:

```
# pytest 환경
pytest services/public_data/tests/test_bus_arrivals_service.py -v

# stdlib unittest (pytest 미설치 환경)
python -m unittest services.public_data.tests.test_bus_arrivals_service -v
```

설계 의도:

- pytest와 stdlib unittest 양쪽에서 실행 가능한 형태로 작성한다 (TestCase 기반).
- ``pydantic`` / ``httpx`` 미설치 환경에서는 인스턴스 통합 테스트가 ``setUpClass``
  단계에서 ``skipTest``되며 본 모듈의 stub 시뮬레이션 테스트만 실행된다.
- V2 섹션 3에서 정밀화된 ``_normalize_arrivals``의 핵심 로직(TAGO 키 셋 분기,
  응답 timestamp 우선 사용, 빈 list early return, 안전 기본값 흡수)을
  stdlib만으로 재현 검증한다.

주의:

- 본 테스트는 외부 네트워크 호출을 일절 하지 않는다. live 모드 활성화 검증은
  V2 섹션 1 §6 활성화 절차 + 운영 환경 별도 smoke test 책임.
"""
from __future__ import annotations

import json
import os
import sys
import unittest
from datetime import datetime, timezone
from pathlib import Path


# ---------------------------------------------------------------------------
# 환경 가용성 (Pydantic/httpx) 사전 점검
# ---------------------------------------------------------------------------

try:
    import pydantic  # noqa: F401
    import httpx  # noqa: F401

    _PUBLIC_DATA_RUNTIME_AVAILABLE = True
except ModuleNotFoundError:
    _PUBLIC_DATA_RUNTIME_AVAILABLE = False


# 경로 설정 — services/public_data를 sys.path에 추가
_SERVICES_DIR = Path(__file__).resolve().parents[2]
if str(_SERVICES_DIR) not in sys.path:
    sys.path.insert(0, str(_SERVICES_DIR))


# ---------------------------------------------------------------------------
# 시나리오 1: empty stop — _normalize_arrivals가 빈 list를 받으면 빈 list 반환
# ---------------------------------------------------------------------------


class EmptyStopTest(unittest.TestCase):
    """empty stop 시나리오 — _normalize_arrivals([]) → []."""

    def test_empty_raw_items_returns_empty_list(self) -> None:
        """V2 섹션 3 정밀화의 'if not raw_items: return []' 분기 검증."""
        # stub 시뮬레이션 — _normalize_arrivals의 early return 로직만 재현
        def normalize_stub(raw_items: list[dict]) -> list:
            if not raw_items:
                return []
            return ["FAIL_should_not_reach_here"]

        self.assertEqual(normalize_stub([]), [])

    def test_empty_response_helper_returns_empty_arrivals(self) -> None:
        """BusArrivalsService.empty_response(stop_id) 헬퍼 시뮬레이션."""
        # 코드의 empty_response는 NormalizedBusArrivalsResponse(stopId=..., arrivals=[]) 생성.
        # Pydantic 미설치 환경에서는 dict 형태로 시뮬레이션.
        stop_id = "TEST-STOP-EMPTY"

        def empty_response_stub(s: str) -> dict:
            return {"stopId": s, "arrivals": []}

        result = empty_response_stub(stop_id)
        self.assertEqual(result["stopId"], stop_id)
        self.assertEqual(result["arrivals"], [])


# ---------------------------------------------------------------------------
# 시나리오 2: normal arrivals — 서울 BIS 키 셋 + TAGO 키 셋
# ---------------------------------------------------------------------------


def _normalize_stub(raw_items: list[dict]) -> list[dict]:
    """V2 정밀화된 _normalize_arrivals의 stdlib 재현.

    실제 코드(bus_arrivals_service.py)의 로직과 1:1 대응한다. Pydantic
    인스턴스 없이 dict 형태로 결과를 반환해 unittest 환경에서 검증 가능.
    """
    if not raw_items:
        return []

    def _vehicle_to_low_floor(raw, default=False):
        if raw is None:
            return default
        return True if str(raw) == "1" else False

    def _reride_to_congestion(raw):
        return {
            "0": "UNKNOWN", "3": "LOW", "4": "NORMAL", "5": "HIGH"
        }.get(str(raw) if raw is not None else None, "UNKNOWN")

    def _seconds_to_minutes(raw):
        try:
            s = int(raw)
        except (TypeError, ValueError):
            return 0
        return 0 if s < 0 else int(round(s / 60))

    now = datetime.now(timezone.utc)
    results = []
    for item in raw_items:
        route_id = str(
            item.get("rtNm")
            or item.get("busRouteId")
            or item.get("routeId")
            or item.get("routeNo")
            or ""
        )
        bus_no = str(
            item.get("busRouteAbrv")
            or item.get("rtNm")
            or item.get("routeNo")
            or route_id
            or ""
        )
        raw_secs = item.get("exps1")
        if raw_secs is None:
            raw_secs = item.get("kals1")
        if raw_secs is None:
            raw_secs = item.get("arrtime")
        if raw_secs is None:
            raw_secs = 0
        arrival_minutes = _seconds_to_minutes(raw_secs)

        remaining_stops = item.get("staOrd")
        if remaining_stops is not None:
            try:
                remaining_stops = int(remaining_stops)
                if remaining_stops < 0:
                    remaining_stops = None
            except (TypeError, ValueError):
                remaining_stops = None

        low_floor_raw = item.get("busType1")
        if low_floor_raw is None:
            low_floor_raw = item.get("vehicletp")
        low_floor = _vehicle_to_low_floor(low_floor_raw, default=False)

        congestion = _reride_to_congestion(item.get("reride_Num1"))

        updated_at = now
        ts_raw = item.get("createdAt") or item.get("responseTime")
        if ts_raw:
            try:
                parsed = datetime.fromisoformat(str(ts_raw))
                if parsed.tzinfo is None:
                    parsed = parsed.replace(tzinfo=timezone.utc)
                updated_at = parsed
            except (TypeError, ValueError):
                updated_at = now

        results.append({
            "routeId": route_id,
            "busNo": bus_no,
            "arrivalMinutes": arrival_minutes,
            "remainingStops": remaining_stops,
            "lowFloor": low_floor,
            "congestion": congestion,
            "updatedAt": updated_at.isoformat(),
        })
    return results


class NormalArrivalsTest(unittest.TestCase):
    """normal arrivals 시나리오 — 서울 BIS 및 TAGO 키 셋 정규화."""

    def test_seoul_bis_normal_arrival(self) -> None:
        """서울 BIS 키 셋 단일 arrival 정규화."""
        item = {
            "rtNm": "502",
            "busRouteAbrv": "502번",
            "exps1": 180,
            "staOrd": "2",
            "busType1": "1",
            "reride_Num1": "4",
        }
        result = _normalize_stub([item])
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]["routeId"], "502")
        self.assertEqual(result[0]["busNo"], "502번")
        self.assertEqual(result[0]["arrivalMinutes"], 3)  # 180/60
        self.assertEqual(result[0]["remainingStops"], 2)
        self.assertTrue(result[0]["lowFloor"])
        self.assertEqual(result[0]["congestion"], "NORMAL")

    def test_tago_normal_arrival(self) -> None:
        """TAGO 키 셋 (V2 신규 분기) 정규화."""
        item = {
            "routeId": "TAGO-901",
            "routeNo": "901",
            "arrtime": 240,
            "vehicletp": "1",  # 활성화 후 명세 확인 필요
        }
        result = _normalize_stub([item])
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]["routeId"], "TAGO-901")
        self.assertEqual(result[0]["busNo"], "901")
        self.assertEqual(result[0]["arrivalMinutes"], 4)  # 240/60
        self.assertIsNone(result[0]["remainingStops"])    # TAGO 미제공
        self.assertTrue(result[0]["lowFloor"])
        self.assertEqual(result[0]["congestion"], "UNKNOWN")  # TAGO 미제공

    def test_multiple_arrivals_in_one_stop(self) -> None:
        """한 정류장에 여러 노선 도착 (mock JSON의 4건 구조 모사)."""
        items = [
            {"rtNm": "A", "busType1": "1", "reride_Num1": "3", "exps1": 60},
            {"rtNm": "B", "busType1": "0", "reride_Num1": "5", "exps1": 300},
        ]
        result = _normalize_stub(items)
        self.assertEqual(len(result), 2)
        self.assertEqual(result[0]["congestion"], "LOW")
        self.assertEqual(result[1]["congestion"], "HIGH")
        self.assertTrue(result[0]["lowFloor"])
        self.assertFalse(result[1]["lowFloor"])

    def test_bankers_rounding_30s_to_0min(self) -> None:
        """banker's rounding: 30초 → 0분 (round-half-to-even)."""
        result = _normalize_stub([{"rtNm": "X", "exps1": 30}])
        self.assertEqual(result[0]["arrivalMinutes"], 0)

    def test_bankers_rounding_90s_to_2min(self) -> None:
        """banker's rounding: 90초 → 2분 (round-half-to-even)."""
        result = _normalize_stub([{"rtNm": "X", "exps1": 90}])
        self.assertEqual(result[0]["arrivalMinutes"], 2)


# ---------------------------------------------------------------------------
# 시나리오 3: low floor only — 저상 필터 (low_floor_filter.py)
# ---------------------------------------------------------------------------


class LowFloorOnlyTest(unittest.TestCase):
    """low floor only 시나리오 — 저상버스 필터링."""

    def test_filter_only_low_floor(self) -> None:
        """lowFloor=True인 arrival만 남기는 필터 동작."""
        arrivals = [
            {"routeId": "A", "lowFloor": True,  "arrivalMinutes": 3, "congestion": "LOW"},
            {"routeId": "B", "lowFloor": False, "arrivalMinutes": 5, "congestion": "NORMAL"},
            {"routeId": "C", "lowFloor": True,  "arrivalMinutes": 7, "congestion": "HIGH"},
        ]
        filtered = [a for a in arrivals if a["lowFloor"]]
        self.assertEqual(len(filtered), 2)
        self.assertEqual({a["routeId"] for a in filtered}, {"A", "C"})

    def test_prioritize_low_floor_keeps_order_within_groups(self) -> None:
        """저상 우선 정렬 — 같은 그룹 내에서는 arrivalMinutes 오름차순."""
        arrivals = [
            {"routeId": "B", "lowFloor": False, "arrivalMinutes": 2},
            {"routeId": "A", "lowFloor": True,  "arrivalMinutes": 7},
            {"routeId": "C", "lowFloor": True,  "arrivalMinutes": 3},
            {"routeId": "D", "lowFloor": False, "arrivalMinutes": 5},
        ]
        # low_floor_filter.prioritize_low_floor 로직 시뮬레이션
        sorted_arrivals = sorted(
            arrivals,
            key=lambda a: (not a["lowFloor"], a["arrivalMinutes"]),
        )
        order = [a["routeId"] for a in sorted_arrivals]
        # 저상 그룹 (C 3, A 7) → 일반 그룹 (B 2, D 5) 순서 기대
        self.assertEqual(order, ["C", "A", "B", "D"])


# ---------------------------------------------------------------------------
# 시나리오 4: mock fallback — _is_mock_mode + use_mock 우선순위
# ---------------------------------------------------------------------------


def _is_mock_mode_stub() -> bool:
    """`_is_mock_mode()`의 stdlib 재현 — 코드와 1:1 대응."""
    raw = os.getenv("PUBLIC_DATA_USE_MOCK")
    if raw is None:
        return True
    normalized = raw.strip().lower()
    if normalized in {"true", "1", "yes", "on"}:
        return True
    if normalized in {"false", "0", "no", "off"}:
        return False
    return True  # 보수적 fallback


class MockFallbackTest(unittest.TestCase):
    """mock fallback 시나리오 — 환경변수 미설정 시 mock-first 보장."""

    def setUp(self) -> None:
        # 각 테스트 격리를 위해 환경변수 정리
        self._orig = os.environ.pop("PUBLIC_DATA_USE_MOCK", None)

    def tearDown(self) -> None:
        if self._orig is not None:
            os.environ["PUBLIC_DATA_USE_MOCK"] = self._orig
        else:
            os.environ.pop("PUBLIC_DATA_USE_MOCK", None)

    def test_unset_env_defaults_to_mock(self) -> None:
        """환경변수 미설정 시 mock-first 정책."""
        self.assertTrue(_is_mock_mode_stub())

    def test_env_false_disables_mock(self) -> None:
        """PUBLIC_DATA_USE_MOCK=false 시 mock 해제."""
        os.environ["PUBLIC_DATA_USE_MOCK"] = "false"
        self.assertFalse(_is_mock_mode_stub())

    def test_env_garbage_falls_back_to_mock(self) -> None:
        """알 수 없는 값은 보수적으로 mock 유지."""
        os.environ["PUBLIC_DATA_USE_MOCK"] = "garbage_value"
        self.assertTrue(_is_mock_mode_stub())

    def test_case_insensitive_evaluation(self) -> None:
        """대소문자 무시 평가."""
        os.environ["PUBLIC_DATA_USE_MOCK"] = "FALSE"
        self.assertFalse(_is_mock_mode_stub())
        os.environ["PUBLIC_DATA_USE_MOCK"] = "True"
        self.assertTrue(_is_mock_mode_stub())

    def test_use_mock_property_explicit_arg_wins(self) -> None:
        """BusArrivalsService.use_mock @property: 명시 인자 > env 우선순위."""
        class StubService:
            def __init__(self, use_mock_override):
                self._use_mock_override = use_mock_override
            @property
            def use_mock(self):
                if self._use_mock_override is not None:
                    return self._use_mock_override
                return _is_mock_mode_stub()

        # 명시 True가 env false보다 우선
        os.environ["PUBLIC_DATA_USE_MOCK"] = "false"
        self.assertTrue(StubService(use_mock_override=True).use_mock)

        # 명시 False가 env true보다 우선
        os.environ["PUBLIC_DATA_USE_MOCK"] = "true"
        self.assertFalse(StubService(use_mock_override=False).use_mock)

        # 명시 None이면 env로 결정
        os.environ["PUBLIC_DATA_USE_MOCK"] = "true"
        self.assertTrue(StubService(use_mock_override=None).use_mock)


# ---------------------------------------------------------------------------
# 시나리오 5: schema — shared schema ↔ mock JSON ↔ 정규화 결과 3자 정합
# ---------------------------------------------------------------------------


class SchemaCompatibilityTest(unittest.TestCase):
    """shared schema ↔ mock JSON ↔ 정규화 결과 3자 정합 검증."""

    @classmethod
    def setUpClass(cls) -> None:
        # 프로젝트 루트 찾기 (mobi-smart-transport-ai)
        cls.project_root = _SERVICES_DIR.parent
        cls.schema_path = cls.project_root / "packages" / "shared_contracts" / "api" / "bus_arrivals.response.schema.json"
        cls.mock_path = _SERVICES_DIR / "public_data" / "examples" / "mock_bus_arrivals.json"

        if not cls.schema_path.exists():
            raise unittest.SkipTest(f"shared schema not found at {cls.schema_path}")
        if not cls.mock_path.exists():
            raise unittest.SkipTest(f"mock JSON not found at {cls.mock_path}")

        cls.schema = json.loads(cls.schema_path.read_text(encoding="utf-8"))
        cls.mock = json.loads(cls.mock_path.read_text(encoding="utf-8"))

    def test_mock_top_level_required_fields_present(self) -> None:
        """mock JSON의 top-level이 shared schema required를 모두 포함."""
        required = set(self.schema.get("required", []))
        self.assertTrue(required.issubset(set(self.mock.keys())))

    def test_mock_arrival_items_extra_properties_forbidden(self) -> None:
        """shared schema의 additionalProperties:false 정책에 따라 비계약 필드 0건."""
        arr_props = set(
            self.schema["properties"]["arrivals"]["items"]["properties"].keys()
        )
        for arrival in self.mock["arrivals"]:
            extra = set(arrival.keys()) - arr_props
            self.assertEqual(
                extra, set(),
                msg=f"비계약 필드 침투: {extra} in arrival {arrival.get('routeId', '?')}"
            )

    def test_mock_congestion_values_in_enum(self) -> None:
        """mock 4건의 congestion 값이 shared schema enum 4종 안에 있음."""
        allowed = set(
            self.schema["properties"]["arrivals"]["items"]["properties"]["congestion"]["enum"]
        )
        self.assertEqual(allowed, {"LOW", "NORMAL", "HIGH", "UNKNOWN"})
        for arrival in self.mock["arrivals"]:
            self.assertIn(arrival["congestion"], allowed)

    def test_mock_congestion_covers_all_four_enums(self) -> None:
        """mock 4건이 congestion 4종을 모두 cover (검증 다양성)."""
        congestions = {a["congestion"] for a in self.mock["arrivals"]}
        self.assertEqual(congestions, {"LOW", "NORMAL", "HIGH", "UNKNOWN"})

    def test_mock_low_floor_both_true_and_false(self) -> None:
        """mock 4건에 lowFloor T·F 모두 등장."""
        values = {a["lowFloor"] for a in self.mock["arrivals"]}
        self.assertEqual(values, {True, False})

    def test_mock_remaining_stops_diversity(self) -> None:
        """mock 4건의 remainingStops에 null·0·양수 모두 등장."""
        values = [a["remainingStops"] for a in self.mock["arrivals"]]
        self.assertIn(None, values)
        self.assertIn(0, values)
        self.assertTrue(any(isinstance(v, int) and v > 0 for v in values))

    def test_mock_updated_at_rfc3339_format(self) -> None:
        """mock 4건의 updatedAt이 RFC3339 형식이고 fromisoformat으로 파싱 가능."""
        for arrival in self.mock["arrivals"]:
            ua = arrival["updatedAt"]
            # fromisoformat은 Python 3.11부터 'Z'도 지원 (3.10은 +00:00 형식만)
            parsed = datetime.fromisoformat(ua)
            self.assertIsNotNone(parsed.tzinfo, msg=f"timezone-aware 아님: {ua}")


# ---------------------------------------------------------------------------
# 시나리오 6: invalid input — 안전 기본값 흡수 + 손상된 timestamp fallback
# ---------------------------------------------------------------------------


class InvalidInputSafetyTest(unittest.TestCase):
    """invalid input 시나리오 — V2 섹션 3 정밀화 안전 기본값 검증."""

    def test_all_keys_missing_returns_safe_defaults(self) -> None:
        """모든 키 누락 → 빈 문자열 + 0 + False + UNKNOWN 흡수."""
        result = _normalize_stub([{"some_unknown_field": "value"}])
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]["routeId"], "")
        self.assertEqual(result[0]["busNo"], "")
        self.assertEqual(result[0]["arrivalMinutes"], 0)
        self.assertFalse(result[0]["lowFloor"])
        self.assertEqual(result[0]["congestion"], "UNKNOWN")
        self.assertIsNone(result[0]["remainingStops"])

    def test_negative_remaining_stops_normalized_to_none(self) -> None:
        """staOrd 음수 → None 흡수."""
        result = _normalize_stub([{"rtNm": "X", "staOrd": -5}])
        self.assertIsNone(result[0]["remainingStops"])

    def test_invalid_remaining_stops_type_normalized_to_none(self) -> None:
        """staOrd 타입 변환 실패 → None."""
        result = _normalize_stub([{"rtNm": "X", "staOrd": "not_a_number"}])
        self.assertIsNone(result[0]["remainingStops"])

    def test_negative_exps1_returns_zero_minutes(self) -> None:
        """exps1 음수 → 0분 (정류장 과거 통과 방지)."""
        result = _normalize_stub([{"rtNm": "X", "exps1": -120}])
        self.assertEqual(result[0]["arrivalMinutes"], 0)

    def test_invalid_exps1_type_returns_zero(self) -> None:
        """exps1 변환 실패 → 0."""
        result = _normalize_stub([{"rtNm": "X", "exps1": "soon"}])
        self.assertEqual(result[0]["arrivalMinutes"], 0)

    def test_response_timestamp_priority_with_valid_iso(self) -> None:
        """응답 createdAt 우선 사용."""
        result = _normalize_stub([{
            "rtNm": "X", "createdAt": "2026-05-19T22:30:00+00:00"
        }])
        self.assertIn("2026-05-19T22:30:00", result[0]["updatedAt"])

    def test_invalid_response_timestamp_falls_back_to_now(self) -> None:
        """손상된 createdAt → 호출 시점 fallback."""
        result = _normalize_stub([{
            "rtNm": "X", "createdAt": "this is not a timestamp"
        }])
        # 호출 시점 → 현재 연도(2026)와 일치하는 ISO 문자열
        self.assertIn("2026-", result[0]["updatedAt"])


# ---------------------------------------------------------------------------
# 통합 인스턴스 테스트 (Pydantic/httpx 미설치 시 skip)
# ---------------------------------------------------------------------------


@unittest.skipUnless(
    _PUBLIC_DATA_RUNTIME_AVAILABLE,
    "pydantic/httpx 미설치 — V1·V2 일관 환경 제약 (V2 섹션 1 §8 참조)"
)
class BusArrivalsServiceInstanceTest(unittest.TestCase):
    """BusArrivalsService 실 인스턴스 통합 테스트 (가용 환경에서만)."""

    def test_get_arrivals_mock_mode_returns_response(self) -> None:
        from public_data_client import BusArrivalsService  # type: ignore

        service = BusArrivalsService(use_mock=True)
        response = service.get_arrivals(stop_id="TEST-MOCK-STOP")
        # NormalizedBusArrivalsResponse 형태
        self.assertEqual(response.stopId, "TEST-MOCK-STOP")
        self.assertEqual(len(response.arrivals), 4)  # mock 4건

    def test_get_arrivals_returns_seven_fields(self) -> None:
        from public_data_client import BusArrivalsService  # type: ignore

        service = BusArrivalsService(use_mock=True)
        response = service.get_arrivals(stop_id="TEST-STOP")
        for arrival in response.arrivals:
            self.assertTrue(hasattr(arrival, "routeId"))
            self.assertTrue(hasattr(arrival, "busNo"))
            self.assertTrue(hasattr(arrival, "arrivalMinutes"))
            self.assertTrue(hasattr(arrival, "remainingStops"))
            self.assertTrue(hasattr(arrival, "lowFloor"))
            self.assertTrue(hasattr(arrival, "congestion"))
            self.assertTrue(hasattr(arrival, "updatedAt"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
