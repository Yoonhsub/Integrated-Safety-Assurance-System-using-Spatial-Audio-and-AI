"""V2 섹션 10 — AI Vision mock pipeline 5 시나리오 검증.

본 모듈은 V2 섹션 8 산출물 (mock_inference_pipeline.py + mock_safety_events.json) +
V2 섹션 9 산출물 (class_taxonomy.json v0.3.0) + V2 섹션 7 후보 schema (pipelines/
README.md §3.4) 의 3자 정합성을 시나리오 단위로 검증한다.

실행 방법::

    pytest ai_vision/pipelines/tests/test_mock_inference_pipeline.py -v
    python -m unittest ai_vision.pipelines.tests.test_mock_inference_pipeline -v

설계 의도:

- V2 섹션 8에서 만든 mock pipeline 동작 회귀가 V2 섹션 9 taxonomy v0.3.0 정밀화 후에도
  깨지지 않았는지 본 테스트로 영속 보장.
- 미래에 taxonomy 또는 fixture 어느 한 쪽이 바뀌어도 본 테스트가 회귀 감지.
- pytest와 stdlib unittest 양쪽에서 실행 가능.
"""
from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path
from typing import Any


# ---------------------------------------------------------------------------
# 경로 설정 — ai_vision/pipelines를 sys.path에 넣어 mock_inference_pipeline import
# ---------------------------------------------------------------------------

_THIS_DIR = Path(__file__).resolve().parent
_PIPELINES_DIR = _THIS_DIR.parent          # ai_vision/pipelines/
_AI_VISION_DIR = _PIPELINES_DIR.parent     # ai_vision/
_PROJECT_ROOT = _AI_VISION_DIR.parent      # mobi-smart-transport-ai/

if str(_PIPELINES_DIR) not in sys.path:
    sys.path.insert(0, str(_PIPELINES_DIR))


# Safety Event Schema 후보의 필수 필드 (V2 섹션 7 §3.4.4)
SCHEMA_REQUIRED_TOP_FIELDS = {
    "eventId", "frameId", "capturedAt",
    "riskLevel", "reason",
}
# Safety Event Schema 후보의 전체 필드 (V2 섹션 7 §3.4.2)
SCHEMA_ALLOWED_TOP_FIELDS = SCHEMA_REQUIRED_TOP_FIELDS | {
    "primaryClass", "detections", "imageSize", "modelInfo", "message",
}
# detection item 의 허용 필드 (V2 섹션 7 §3.4.2)
SCHEMA_DETECTION_FIELDS = {"classId", "bbox", "score"}
BBOX_FIELDS = {"x", "y", "w", "h"}
RISK_LEVELS = {"info", "warn", "danger"}


# ---------------------------------------------------------------------------
# 시나리오 1: mock_inference_pipeline 호출자 API 동작 회귀 (V2 섹션 8 산출물)
# ---------------------------------------------------------------------------


class MockPipelineApiTest(unittest.TestCase):
    """mock_inference_pipeline.py 외부 API 동작 회귀."""

    def setUp(self) -> None:
        import mock_inference_pipeline  # type: ignore
        self.module = mock_inference_pipeline

    def test_get_all_events_returns_four(self) -> None:
        events = self.module.get_all_events()
        self.assertEqual(len(events), 4)

    def test_get_events_by_risk_filters_correctly(self) -> None:
        self.assertEqual(len(self.module.get_events_by_risk("info")), 1)
        self.assertEqual(len(self.module.get_events_by_risk("warn")), 1)
        self.assertEqual(len(self.module.get_events_by_risk("danger")), 2)

    def test_get_events_by_risk_unknown_enum_returns_empty(self) -> None:
        self.assertEqual(self.module.get_events_by_risk("not_a_real_enum"), [])

    def test_get_event_by_id_returns_dict_or_none(self) -> None:
        known = "11111111-1111-4111-8111-111111111111"
        ev = self.module.get_event_by_id(known)
        self.assertIsNotNone(ev)
        self.assertEqual(ev["riskLevel"], "info")
        self.assertIsNone(self.module.get_event_by_id("nonexistent-id"))

    def test_get_all_events_returns_copies_not_references(self) -> None:
        """원본 변경이 다음 호출에 영향 주지 않는다 (사본 보장)."""
        ev1 = self.module.get_all_events()
        ev1[0]["eventId"] = "MUTATED"
        ev2 = self.module.get_all_events()
        self.assertNotEqual(ev2[0]["eventId"], "MUTATED")

    def test_get_fixture_schema_reference_contains_section_3_4(self) -> None:
        ref = self.module.get_fixture_schema_reference()
        self.assertIn("§3.4", ref)

    def test_corrupted_json_raises_mock_inference_error(self) -> None:
        import tempfile
        with tempfile.NamedTemporaryFile(
            "w", suffix=".json", delete=False, encoding="utf-8"
        ) as f:
            f.write("{ not valid json }")
            bad_path = Path(f.name)
        try:
            with self.assertRaises(self.module.MockInferenceError):
                self.module.get_all_events(path=bad_path)
        finally:
            bad_path.unlink(missing_ok=True)

    def test_missing_file_raises_mock_inference_error(self) -> None:
        with self.assertRaises(self.module.MockInferenceError):
            self.module.get_all_events(path=Path("/does/not/exist.json"))


# ---------------------------------------------------------------------------
# 시나리오 2: fixture 각 event 가 §3.4 schema 후보를 충족하는가
# ---------------------------------------------------------------------------


class FixtureSchemaComplianceTest(unittest.TestCase):
    """fixture 4건이 V2 섹션 7 §3.4 schema 후보의 필수·허용 필드를 충족."""

    @classmethod
    def setUpClass(cls) -> None:
        import mock_inference_pipeline  # type: ignore
        cls.events = mock_inference_pipeline.get_all_events()

    def test_each_event_has_required_fields(self) -> None:
        for ev in self.events:
            missing = SCHEMA_REQUIRED_TOP_FIELDS - set(ev.keys())
            self.assertEqual(
                missing, set(),
                msg=f"event {ev.get('eventId')} 누락 필수 필드: {missing}"
            )

    def test_each_event_has_only_allowed_top_fields(self) -> None:
        for ev in self.events:
            extra = set(ev.keys()) - SCHEMA_ALLOWED_TOP_FIELDS
            self.assertEqual(
                extra, set(),
                msg=f"event {ev.get('eventId')} 비계약 필드: {extra}"
            )

    def test_riskLevel_in_enum(self) -> None:
        for ev in self.events:
            self.assertIn(ev["riskLevel"], RISK_LEVELS)

    def test_detections_each_item_has_correct_keys(self) -> None:
        for ev in self.events:
            for det in ev.get("detections", []):
                self.assertEqual(set(det.keys()), SCHEMA_DETECTION_FIELDS)

    def test_detections_bbox_has_four_keys(self) -> None:
        for ev in self.events:
            for det in ev.get("detections", []):
                self.assertEqual(set(det["bbox"].keys()), BBOX_FIELDS)

    def test_detections_bbox_values_in_unit_range(self) -> None:
        for ev in self.events:
            for det in ev.get("detections", []):
                for k, v in det["bbox"].items():
                    self.assertGreaterEqual(v, 0.0, msg=f"bbox[{k}] < 0 in {ev['eventId']}")
                    self.assertLessEqual(v, 1.0, msg=f"bbox[{k}] > 1 in {ev['eventId']}")

    def test_detections_score_in_unit_range(self) -> None:
        for ev in self.events:
            for det in ev.get("detections", []):
                self.assertGreaterEqual(det["score"], 0.0)
                self.assertLessEqual(det["score"], 1.0)

    def test_empty_detections_case_present(self) -> None:
        """V2 섹션 7 §3.4.4 명시: detections 빈 list 허용. 4건 중 최소 1건이 빈 list."""
        empty_count = sum(1 for ev in self.events if ev.get("detections") == [])
        self.assertGreaterEqual(empty_count, 1, msg="빈 detections 케이스가 없음")

    def test_imageSize_optional_but_well_formed_when_present(self) -> None:
        for ev in self.events:
            if "imageSize" in ev:
                self.assertEqual(set(ev["imageSize"].keys()), {"width", "height"})
                self.assertGreater(ev["imageSize"]["width"], 0)
                self.assertGreater(ev["imageSize"]["height"], 0)

    def test_modelInfo_optional_but_well_formed_when_present(self) -> None:
        for ev in self.events:
            if "modelInfo" in ev:
                self.assertIn("name", ev["modelInfo"])
                self.assertIn("version", ev["modelInfo"])


# ---------------------------------------------------------------------------
# 시나리오 3: fixture ↔ taxonomy v0.3.0 정합 (cross-check)
# ---------------------------------------------------------------------------


class FixtureTaxonomyCrosscheckTest(unittest.TestCase):
    """fixture 4건과 taxonomy v0.3.0 reason_codes / classes 양방향 정합."""

    @classmethod
    def setUpClass(cls) -> None:
        import mock_inference_pipeline  # type: ignore
        cls.events = mock_inference_pipeline.get_all_events()

        taxonomy_path = _AI_VISION_DIR / "dataset_plan" / "class_taxonomy.json"
        if not taxonomy_path.exists():
            raise unittest.SkipTest(f"taxonomy not found: {taxonomy_path}")
        cls.taxonomy = json.loads(taxonomy_path.read_text(encoding="utf-8"))

        cls.class_ids = {c["id"] for c in cls.taxonomy["classes"]}
        cls.reason_codes = {r["code"]: r for r in cls.taxonomy["reason_codes"]}

    def test_taxonomy_version_at_least_v0_3(self) -> None:
        """V2 섹션 9 정밀화로 0.3.0 이상."""
        major, minor, _ = self.taxonomy["version"].split(".")
        self.assertGreaterEqual((int(major), int(minor)), (0, 3))

    def test_fixture_primaryClass_in_taxonomy_classes(self) -> None:
        for ev in self.events:
            if "primaryClass" in ev:
                self.assertIn(
                    ev["primaryClass"], self.class_ids,
                    msg=f"primaryClass={ev['primaryClass']!r} not in taxonomy classes"
                )

    def test_fixture_reason_in_taxonomy_reason_codes(self) -> None:
        for ev in self.events:
            self.assertIn(
                ev["reason"], self.reason_codes,
                msg=f"reason={ev['reason']!r} not in taxonomy reason_codes"
            )

    def test_fixture_riskLevel_matches_reason_codes_default(self) -> None:
        """V2 섹션 7 §3.4 명시: 같은 reason은 default_risk_level과 일관성 유지."""
        for ev in self.events:
            reason = self.reason_codes[ev["reason"]]
            self.assertEqual(
                ev["riskLevel"], reason["default_risk_level"],
                msg=f"event {ev['eventId']}: riskLevel={ev['riskLevel']!r} vs "
                    f"reason_codes[{ev['reason']!r}].default_risk_level="
                    f"{reason['default_risk_level']!r}"
            )

    def test_detections_classId_all_in_taxonomy_classes(self) -> None:
        for ev in self.events:
            for det in ev.get("detections", []):
                self.assertIn(
                    det["classId"], self.class_ids,
                    msg=f"detection.classId={det['classId']!r} not in taxonomy"
                )

    def test_primaryClass_present_in_detections_when_detections_nonempty(self) -> None:
        """V2 섹션 7 §3.4.4 cross-field 검증: primaryClass가 있고 detections가
        비어있지 않으면 detections에 같은 classId가 최소 1개 존재."""
        for ev in self.events:
            primary = ev.get("primaryClass")
            dets = ev.get("detections", [])
            if primary and dets:
                class_ids_in_dets = {d["classId"] for d in dets}
                self.assertIn(
                    primary, class_ids_in_dets,
                    msg=f"event {ev['eventId']}: primaryClass={primary!r} "
                        f"not found in detections classIds {class_ids_in_dets}"
                )

    def test_reason_trigger_primary_class_matches_event_primary_class(self) -> None:
        """fixture.reason의 trigger_primary_class와 fixture.primaryClass가 일치."""
        for ev in self.events:
            reason_meta = self.reason_codes[ev["reason"]]
            trigger = reason_meta["trigger_primary_class"]
            self.assertEqual(
                ev.get("primaryClass"), trigger,
                msg=f"event {ev['eventId']}: primaryClass={ev.get('primaryClass')!r} "
                    f"vs reason_codes[{ev['reason']!r}].trigger={trigger!r}"
            )


# ---------------------------------------------------------------------------
# 시나리오 4: taxonomy v0.3.0 internal 정합 (자기자신 일관성)
# ---------------------------------------------------------------------------


class TaxonomyInternalConsistencyTest(unittest.TestCase):
    """taxonomy v0.3.0의 reason_codes ↔ classes 양방향 정합 + V2 신규 필드 형식."""

    @classmethod
    def setUpClass(cls) -> None:
        taxonomy_path = _AI_VISION_DIR / "dataset_plan" / "class_taxonomy.json"
        cls.taxonomy = json.loads(taxonomy_path.read_text(encoding="utf-8"))
        cls.class_ids = {c["id"] for c in cls.taxonomy["classes"]}
        cls.reason_codes_set = {r["code"] for r in cls.taxonomy["reason_codes"]}

    def test_reason_codes_trigger_classes_all_valid(self) -> None:
        for reason in self.taxonomy["reason_codes"]:
            self.assertIn(
                reason["trigger_primary_class"], self.class_ids,
                msg=f"reason_codes[{reason['code']!r}].trigger_primary_class "
                    f"={reason['trigger_primary_class']!r} not in classes"
            )

    def test_class_related_reasons_all_valid(self) -> None:
        for cls_def in self.taxonomy["classes"]:
            for r in cls_def.get("related_reasons", []):
                self.assertIn(
                    r, self.reason_codes_set,
                    msg=f"class[{cls_def['id']!r}].related_reasons has unknown {r!r}"
                )

    def test_each_class_has_v2_fields(self) -> None:
        """V2 섹션 9 신규 4 필드가 모든 학습 클래스에 존재."""
        required = {
            "default_risk_level", "detection_threshold",
            "user_message_templates", "related_reasons",
        }
        for cls_def in self.taxonomy["classes"]:
            missing = required - set(cls_def.keys())
            self.assertEqual(
                missing, set(),
                msg=f"class[{cls_def['id']!r}] V2 신규 필드 누락: {missing}"
            )

    def test_default_risk_level_in_enum(self) -> None:
        for cls_def in self.taxonomy["classes"]:
            self.assertIn(cls_def["default_risk_level"], RISK_LEVELS)
        for reason in self.taxonomy["reason_codes"]:
            self.assertIn(reason["default_risk_level"], RISK_LEVELS)

    def test_detection_threshold_in_unit_range(self) -> None:
        for cls_def in self.taxonomy["classes"]:
            t = cls_def["detection_threshold"]
            self.assertIsInstance(t, (int, float))
            self.assertGreater(t, 0.0)
            self.assertLessEqual(t, 1.0)

    def test_user_message_templates_has_ko(self) -> None:
        for cls_def in self.taxonomy["classes"]:
            templates = cls_def["user_message_templates"]
            self.assertIsInstance(templates, dict)
            self.assertIn("ko", templates)
            self.assertIsInstance(templates["ko"], str)
            self.assertGreater(len(templates["ko"]), 0)

    def test_reason_codes_have_ko_message(self) -> None:
        for reason in self.taxonomy["reason_codes"]:
            self.assertIn("ko_message", reason)
            self.assertIsInstance(reason["ko_message"], str)
            self.assertGreater(len(reason["ko_message"]), 0)


# ---------------------------------------------------------------------------
# 시나리오 5: cross-team 출발점 — backend 호환 가능성 검증
# ---------------------------------------------------------------------------


class BackendCompatibilityTest(unittest.TestCase):
    """V2 섹션 7 §3.4.6 backend 호환 가능성 분석을 시나리오로 검증.

    backend(심현석)가 Pydantic StrictApiModel 패턴으로 본 fixture 4건을 받았을 때
    additionalProperties:false 정책에 위배되는 항목이 없는지 확인.
    """

    @classmethod
    def setUpClass(cls) -> None:
        import mock_inference_pipeline  # type: ignore
        cls.events = mock_inference_pipeline.get_all_events()

    def test_each_event_serializable_as_json(self) -> None:
        """backend가 HTTP body로 받을 수 있는 JSON으로 직렬화 가능."""
        for ev in self.events:
            serialized = json.dumps(ev)
            self.assertIsInstance(serialized, str)
            roundtrip = json.loads(serialized)
            self.assertEqual(roundtrip["eventId"], ev["eventId"])

    def test_capturedAt_is_iso8601_like_string(self) -> None:
        """RFC3339 = ISO 8601. T 구분자 + timezone offset 존재."""
        for ev in self.events:
            ts = ev["capturedAt"]
            self.assertIsInstance(ts, str)
            self.assertIn("T", ts)
            # +HH:MM 또는 Z 형태 timezone (RFC3339 요구)
            has_tz = "+" in ts[10:] or "-" in ts[10:] or ts.endswith("Z")
            self.assertTrue(has_tz, msg=f"capturedAt={ts!r} has no timezone offset")

    def test_eventId_and_frameId_are_uuid_v4_format(self) -> None:
        """UUID v4: 8-4-4-4-12 hex with version=4 indicator."""
        import re
        uuid_pattern = re.compile(
            r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
            re.IGNORECASE,
        )
        for ev in self.events:
            self.assertRegex(ev["eventId"], uuid_pattern)
            self.assertRegex(ev["frameId"], uuid_pattern)

    def test_eventId_unique_across_fixture(self) -> None:
        """backend 멱등성 검증을 위해 eventId는 fixture 내부에서 unique."""
        ids = [ev["eventId"] for ev in self.events]
        self.assertEqual(len(ids), len(set(ids)))

    def test_no_unexpected_top_level_fields_for_strict_api_model(self) -> None:
        """backend의 StrictApiModel(extra='forbid') 정책상 §3.4 외 필드 침투 0건."""
        for ev in self.events:
            extra = set(ev.keys()) - SCHEMA_ALLOWED_TOP_FIELDS
            self.assertEqual(extra, set())


if __name__ == "__main__":
    unittest.main(verbosity=2)
