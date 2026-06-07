from fastapi.testclient import TestClient

from app.main import app
from app.services.firebase_client import get_firebase_client
from app.services.v3_guidance_store import v3_guidance_store

client = TestClient(app)


def setup_function() -> None:
    v3_guidance_store.clear()
    get_firebase_client().clear_mock_store()


def _say(session_id: str, utterance: str):
    return client.post("/agent/converse", json={"sessionId": session_id, "wakeWord": "자비스", "utterance": utterance})


def _seed_waiting_session(session_id: str = "s1") -> None:
    assert _say(session_id, "자비스, 나 사창사거리 가야 하는데 몇 번 버스 타야 돼?").status_code == 200
    assert _say(session_id, "응, 6분 뒤 오는 걸로 안내해줘.").status_code == 200


def test_agent_rule_fallback_wake_route_arrival_select_flow() -> None:
    wake = _say("s1", "자비스")
    assert wake.status_code == 200
    assert wake.json()["intent"] == "WAKE_ONLY"
    assert wake.json()["message"] == "네, 말씀하세요."
    assert wake.json()["usedGemini"] is False

    route = _say("s1", "자비스, 나 사창사거리 가야 하는데 몇 번 버스 타야 돼?")
    assert route.status_code == 200
    route_body = route.json()
    assert route_body["intent"] == "FIND_ROUTE"
    assert route_body["state"] == "ROUTE_RECOMMENDED"

    arrival = _say("s1", "자비스, 그 버스 언제 와?")
    assert arrival.status_code == 200
    assert arrival.json()["intent"] == "QUERY_ARRIVAL"
    assert "502" in arrival.json()["message"]

    select = _say("s1", "응, 6분 뒤 오는 걸로 안내해줘.")
    assert select.status_code == 200
    assert select.json()["intent"] == "SELECT_ARRIVAL"
    assert select.json()["state"] == "WAITING_FOR_BUS"

    state = client.get("/guidance/state", params={"sessionId": "s1"}).json()
    assert state["targetBusId"] == "BUS_2"
    assert state["geofenceArmed"] is False


def test_agent_destination_correction_and_change_are_session_safe() -> None:
    _seed_waiting_session("s1")

    correction = _say("s1", "사직사거리가 아니라 사창사거리야")
    assert correction.status_code == 200
    assert correction.json()["intent"] == "CORRECT_DESTINATION"
    state = client.get("/guidance/state", params={"sessionId": "s1"}).json()
    assert state["selectedDestination"] == "사창사거리"
    assert state["selectedStopId"] == "mock-stop-001"

    change = _say("s1", "목적지 충북대병원으로 바꿔줘")
    assert change.status_code == 200
    assert change.json()["intent"] == "CHANGE_DESTINATION"
    state = client.get("/guidance/state", params={"sessionId": "s1"}).json()
    assert state["selectedDestination"] == "충북대병원"
    assert state["selectedRouteNo"] == "823"
    assert state["selectedStopId"] == "mock-stop-002"
    assert state["targetBusId"] is None


def test_guidance_invalid_transition_and_session_isolation() -> None:
    first = client.post("/guidance/session", json={"sessionId": "s1", "wakeWord": "자비스"})
    second = client.post("/guidance/session", json={"sessionId": "s2", "wakeWord": "모비"})
    assert first.status_code == 200
    assert second.status_code == 200

    invalid = client.post("/guidance/event", json={"sessionId": "s1", "event": "BOARDED", "payload": {}})
    assert invalid.status_code == 409
    assert invalid.json()["error"]["code"] == "INVALID_GUIDANCE_TRANSITION"

    s1 = client.get("/guidance/state", params={"sessionId": "s1"}).json()
    s2 = client.get("/guidance/state", params={"sessionId": "s2"}).json()
    assert s1["state"] == "IDLE"
    assert s2["state"] == "IDLE"
    assert s2["wakeWord"] == "모비"


def test_guidance_normal_boarding_and_missed_bus_state_flow() -> None:
    client.post("/guidance/session", json={"sessionId": "s1", "wakeWord": "자비스"})
    route = {
        "destination": "사창사거리",
        "routeNo": "502",
        "routeId": "mock-route-502",
        "stopId": "mock-stop-001",
        "stopName": "사창사거리 정류장",
        "targetBusId": "BUS_2",
    }
    assert client.post("/guidance/event", json={"sessionId": "s1", "event": "ROUTE_SELECTED", "payload": route}).json()["state"] == "ROUTE_SELECTED"
    assert client.post("/guidance/event", json={"sessionId": "s1", "event": "ARRIVED_AT_STOP", "payload": {}}).json()["geofenceArmed"] is True
    assert client.post("/guidance/event", json={"sessionId": "s1", "event": "BOARDING_CONFIRMATION", "payload": {}}).json()["state"] == "BOARDING_CONFIRMATION"
    assert client.post("/guidance/event", json={"sessionId": "s1", "event": "MISSED_BUS", "payload": {}}).json()["state"] == "MISSED_BUS"
    replan = client.post("/guidance/event", json={"sessionId": "s1", "event": "REPLAN_NEXT_BUS", "payload": {}})
    assert replan.status_code == 200
    assert replan.json()["state"] == "REPLAN_NEXT_BUS"
    assert replan.json()["targetBusId"] == "BUS_502_NEXT"


def test_geofence_is_not_armed_before_arrival_and_warns_after_arrival() -> None:
    _seed_waiting_session("s1")

    before = client.post("/mock/geofence", json={"sessionId": "s1", "event": "LEFT_WAITING_AREA"})
    assert before.status_code == 200
    before_body = before.json()
    assert before_body["geofenceArmed"] is False
    assert before_body["cue"]["type"] == "NONE"

    arrived = client.post("/mock/geofence", json={"sessionId": "s1", "event": "ARRIVED_AT_STOP"})
    assert arrived.status_code == 200
    assert arrived.json()["geofenceArmed"] is True

    left = client.post("/mock/geofence", json={"sessionId": "s1", "event": "LEFT_WAITING_AREA"})
    assert left.status_code == 200
    assert left.json()["cue"]["type"] == "GEOFENCE_WARNING"
    assert left.json()["cue"]["ttsMode"] == "SAFETY_LOCAL"

    danger = client.post("/mock/geofence", json={"sessionId": "s1", "event": "DANGER_ZONE"})
    assert danger.status_code == 200
    assert danger.json()["cue"]["type"] == "DANGER"
    assert danger.json()["cue"]["ttsMode"] == "SAFETY_LOCAL"

    returned = client.post("/mock/geofence", json={"sessionId": "s1", "event": "RETURNED_TO_STOP"})
    assert returned.status_code == 200
    assert returned.json()["state"] == "WAITING_FOR_BUS"
    assert returned.json()["cue"]["type"] == "NONE"


def test_beacon_wrong_bus_target_mid_target_near_and_session_persistence() -> None:
    _seed_waiting_session("s1")
    client.post("/mock/geofence", json={"sessionId": "s1", "event": "ARRIVED_AT_STOP"})

    wrong = client.post(
        "/mock/beacons",
        json={
            "sessionId": "s1",
            "targetBusId": "BUS_2",
            "targetRouteNo": "502",
            "beacons": [
                {"busId": "BUS_1", "routeNo": "511", "distanceMeters": 1.5, "rssi": -55},
                {"busId": "BUS_2", "routeNo": "502", "distanceMeters": 7.0, "rssi": -70},
            ],
        },
    )
    assert wrong.status_code == 200
    assert wrong.json()["decision"] == "WRONG_BUS_NEAR"
    assert wrong.json()["cue"]["ttsMode"] == "SAFETY_LOCAL"
    assert wrong.json()["nearestBeacon"]["busId"] == "BUS_1"
    assert wrong.json()["targetBus"]["busId"] == "BUS_2"

    ask_wrong = _say("s1", "자비스, 지금 앞에 온 버스 타도 돼?")
    assert ask_wrong.status_code == 200
    assert ask_wrong.json()["intent"] == "ASK_CAN_BOARD_CURRENT_BUS"
    assert ask_wrong.json()["ttsMode"] == "SAFETY_LOCAL"
    assert "아니에요" in ask_wrong.json()["message"]

    near = client.post(
        "/mock/beacons",
        json={
            "sessionId": "s1",
            "targetBusId": "BUS_2",
            "targetRouteNo": "502",
            "beacons": [{"busId": "BUS_2", "routeNo": "502", "distanceMeters": 2.0, "rssi": -58}],
        },
    )
    assert near.status_code == 200
    assert near.json()["decision"] == "TARGET_BUS_NEAR"
    assert near.json()["cue"]["type"] == "TARGET_BUS_NEAR"

    state = client.get("/guidance/state", params={"sessionId": "s1"}).json()
    assert state["state"] == "BOARDING_CONFIRMATION"
    assert state["lastDecision"] == "TARGET_BUS_NEAR"
    assert state["nearestBeacon"]["busId"] == "BUS_2"
    assert state["targetBus"]["busId"] == "BUS_2"

    ask_yes = _say("s1", "자비스, 지금 앞에 온 버스 타도 돼?")
    assert ask_yes.status_code == 200
    assert "네" in ask_yes.json()["message"]


def test_beacon_empty_mid_and_rssi_tie_break() -> None:
    _seed_waiting_session("s1")

    empty = client.post("/mock/beacons", json={"sessionId": "s1", "targetBusId": "BUS_2", "targetRouteNo": "502", "beacons": []})
    assert empty.status_code == 200
    assert empty.json()["decision"] == "NO_BEACON"

    mid = client.post(
        "/mock/beacons",
        json={
            "sessionId": "s1",
            "targetBusId": "BUS_2",
            "targetRouteNo": "502",
            "beacons": [{"busId": "BUS_2", "routeNo": "502", "distanceMeters": 8.0, "rssi": -72}],
        },
    )
    assert mid.status_code == 200
    assert mid.json()["decision"] == "TARGET_BUS_MID"

    rssi = client.post(
        "/mock/beacons",
        json={
            "sessionId": "s1",
            "targetRouteNo": "502",
            "beacons": [
                {"busId": "BUS_WEAK", "routeNo": "502", "rssi": -70},
                {"busId": "BUS_STRONG", "routeNo": "502", "rssi": -55},
            ],
        },
    )
    assert rssi.status_code == 200
    assert rssi.json()["nearestBeacon"]["busId"] == "BUS_STRONG"
    assert rssi.json()["targetBus"]["busId"] == "BUS_STRONG"
    assert rssi.json()["decision"] == "TARGET_BUS_NEAR"


def test_missed_bus_report_replans_next_bus_without_stale_beacon_decision() -> None:
    _seed_waiting_session("s1")
    client.post(
        "/mock/beacons",
        json={
            "sessionId": "s1",
            "targetBusId": "BUS_2",
            "targetRouteNo": "502",
            "beacons": [{"busId": "BUS_2", "routeNo": "502", "distanceMeters": 2.0}],
        },
    )

    missed = _say("s1", "자비스, 나 못 탔어.")
    assert missed.status_code == 200
    assert missed.json()["intent"] == "REPORT_MISSED_BUS"
    assert missed.json()["state"] == "WAITING_FOR_BUS"

    state = client.get("/guidance/state", params={"sessionId": "s1"}).json()
    assert state["targetBusId"] == "BUS_502_NEXT"
    assert state["lastDecision"] is None
    assert state["nearestBeacon"] is None
    assert state["targetBus"] is None
