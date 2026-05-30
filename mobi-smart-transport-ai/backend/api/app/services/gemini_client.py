from __future__ import annotations

import os


def is_available() -> bool:
    return bool(os.getenv("GEMINI_API_KEY"))


def extract_intent_and_slots(utterance: str) -> dict | None:
    """Returns None if Gemini is unavailable or fails."""
    if not is_available():
        return None
    try:
        import google.generativeai as genai  # type: ignore
        genai.configure(api_key=os.getenv("GEMINI_API_KEY"))
        model = genai.GenerativeModel("gemini-pro")
        prompt = (
            "아래 한국어 발화에서 intent와 slots를 JSON으로 추출해줘.\n"
            "intent는 FIND_ROUTE, GET_BUS_ARRIVAL, SELECT_ARRIVAL, ASK_CURRENT_STATUS, "
            "ASK_CAN_BOARD_CURRENT_BUS, CORRECT_DESTINATION, CHANGE_DESTINATION, "
            "CONFIRM_BOARDED, REPORT_MISSED_BUS, SET_WAKE_WORD, WAKE_ONLY, UNKNOWN 중 하나.\n"
            f"발화: {utterance}\n"
            "응답 형식: {\"intent\": \"...\", \"slots\": {...}}"
        )
        response = model.generate_content(prompt)
        import json, re
        match = re.search(r'\{.*\}', response.text, re.DOTALL)
        if match:
            return json.loads(match.group())
    except Exception:
        pass
    return None
