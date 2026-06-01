from app.services import v3_gemini_service


def test_route_plan_reply_rejects_vision_required_crossing_claim(monkeypatch) -> None:
    captured = {}

    def fake_generate(**kwargs):
        captured.update(kwargs)
        return "도로를 건너 오른쪽 정류장에서 862번을 타면 돼."

    monkeypatch.setattr(v3_gemini_service, "_generate", fake_generate)

    reply = v3_gemini_service.generate_route_plan_reply(
        route_plan={"status": "RESOLVED", "recommendedPlan": {"segments": []}},
        utterance="상당산성 가고 싶어",
        wake_word="자비스",
    )

    assert reply is None
    assert captured["thinking_budget"] == 128
    assert "RoutePlan JSON" in captured["system_instruction"]
    assert "새 버스번호" in captured["system_instruction"]


def test_dynamic_reply_rejects_vision_required_side_claim(monkeypatch) -> None:
    monkeypatch.setattr(
        v3_gemini_service,
        "_generate",
        lambda **_: "건너편 정류장에서 기다리면 돼.",
    )

    reply = v3_gemini_service.generate_dynamic_response(
        intent="QUERY_ARRIVAL",
        utterance="언제 와?",
        wake_word="자비스",
        context_data={"arrivals": []},
    )

    assert reply is None


def test_missing_gemini_key_keeps_route_plan_reply_optional(monkeypatch) -> None:
    monkeypatch.delenv("GEMINI_API_KEY", raising=False)

    reply = v3_gemini_service.generate_route_plan_reply(
        route_plan={"status": "NO_ROUTE", "question": "경로를 찾지 못했어."},
        utterance="어떻게 가?",
        wake_word="자비스",
    )

    assert reply is None


def test_route_plan_reply_falls_back_to_flash_when_pro_is_unavailable(monkeypatch) -> None:
    models = []

    def fake_generate(**kwargs):
        models.append(kwargs["model"])
        return None if len(models) == 1 else "확인된 RoutePlan 기준으로 안내할게."

    monkeypatch.setattr(v3_gemini_service, "_generate", fake_generate)

    reply = v3_gemini_service.generate_route_plan_reply(
        route_plan={"status": "RESOLVED", "recommendedPlan": {"segments": []}},
        utterance="상당산성 가고 싶어",
        wake_word="자비스",
    )

    assert reply == "확인된 RoutePlan 기준으로 안내할게."
    assert models == ["gemini-2.5-pro", "gemini-2.5-flash"]


def test_route_plan_reply_sends_compact_verified_payload_to_gemini(monkeypatch) -> None:
    captured = {}

    def fake_generate(**kwargs):
        captured.update(kwargs)
        return "확인된 경로만 안내할게."

    monkeypatch.setattr(v3_gemini_service, "_generate", fake_generate)

    v3_gemini_service.generate_route_plan_reply(
        route_plan={
            "status": "RESOLVED",
            "rawProviderEvidence": {"large": "provider payload"},
            "alternatives": [{"planId": "alt"}],
            "recommendedPlan": {
                "planSource": "ODSAY_ENRICHED",
                "verificationStatus": "VERIFIED_WITH_TAGO",
                "summary": "요약",
                "boardingInstruction": "승차 안내",
                "warnings": [],
                "rawProviderEvidence": {"large": "candidate evidence"},
                "segments": [
                    {"routeNo": "509", "routeId": "CJB-509", "arrivals": [{"arrivalMinutes": 3}]},
                    {"routeNo": "862", "routeId": "CJB-862", "arrivals": [{"arrivalMinutes": 8}]},
                ],
            },
        },
        utterance="상당산성 가고 싶어",
        wake_word="자비스",
    )

    prompt = captured["prompt"]
    assert "rawProviderEvidence" not in prompt
    assert "alternatives" not in prompt
    assert '"arrivalMinutes": 3' in prompt
    assert '"arrivalMinutes": 8' not in prompt
