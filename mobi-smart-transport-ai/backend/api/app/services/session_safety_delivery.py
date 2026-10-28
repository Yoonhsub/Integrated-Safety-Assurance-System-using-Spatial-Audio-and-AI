"""Ephemeral, explicitly bound safety delivery. Restart/reconnect never replays history."""
import os
from datetime import datetime, timezone
from app.security import auth_error, require_role
from app.services.v3_guidance_store import v3_guidance_store
from app.services.vision_binding_service import FreshnessPolicy


def synthetic_enabled():
    return os.getenv("APP_ENV") == "test" and os.getenv("MOBI_SYNTHETIC_GUIDANCE") == "true"


def validate_binding(session_id, generation, payload):
    require_role("admin")
    with v3_guidance_store.vision_scope(session_id) as session:
        if not generation or session.vision_generation != generation:
            raise auth_error(409, "Inactive safety generation")
        if payload.userId is not None and payload.userId != session.owner_uid:
            raise auth_error(403, "Safety owner mismatch")
        if payload.source == "ai_vision_mock":
            if not synthetic_enabled():
                raise auth_error(403, "Synthetic delivery is disabled")
        elif payload.source != "ai_vision_live":
            raise auth_error(422, "Unsupported safety source")


def publish(session_id, generation, record):
    validate_binding(session_id, generation, record)
    policy = FreshnessPolicy.from_environment()
    now = datetime.now(timezone.utc)
    with v3_guidance_store.vision_scope(session_id) as session:
        # Recheck under the session lock after persistence. Reset cannot retarget.
        if session.vision_generation != generation:
            raise auth_error(409, "Inactive safety generation")
        stamp = record.timestamp
        age = (now - stamp).total_seconds()
        key = record.metadata.get("visionEventId", record.eventId)
        if (age < -policy.future_skew or age >= policy.max_age or
                key in session.safety_seen or
                (session.safety_watermark is not None and stamp <= session.safety_watermark)):
            return
        # Fail closed for unreviewed policies; no arbitrary producer text, geometry,
        # boarding decisions or new priority thresholds are exposed to passengers.
        if (record.metadata.get("reason") != "bus_door_visible" or
                record.metadata.get("primaryClass") != "bus_door" or
                record.metadata.get("riskLevel") != "info" or
                record.confidence is None or record.confidence < .55):
            return
        synthetic = record.source == "ai_vision_mock"
        if record.metadata.get("modelProvider") != ("mock" if synthetic else "ultralytics"):
            return
        session.safety_seen.add(key)
        session.safety_watermark = stamp
        session.safety_sequence += 1
        message = ("검증용 합성 이벤트입니다. " if synthetic else "") + "출입문 검출 정보가 수신되었습니다. 방향과 승차 가능 여부는 확인되지 않았습니다."
        session.safety_items.append(dict(sequence=session.safety_sequence,
            eventId=record.eventId, message=message, timestamp=stamp.isoformat(),
            expiresAt=min(stamp.timestamp()+policy.max_age, now.timestamp()+policy.observation_ttl),
            synthetic=synthetic, priority="info"))
        session.safety_items[:] = session.safety_items[-128:]
        # Strict timestamp watermark also rejects evicted event replays.
        if len(session.safety_seen) > 128:
            session.safety_seen = {key}


def poll(session_id, after=None, generation=None):
    now = datetime.now(timezone.utc).timestamp()
    with v3_guidance_store.observation_scope(session_id) as session:
        baseline = after is None or generation != session.vision_generation
        if after is not None and (after < 0 or after > session.safety_sequence):
            raise auth_error(409, "Invalid safety cursor")
        events = [] if baseline else [
            {**item, "validForSeconds": item["expiresAt"]-now}
            for item in session.safety_items
            if item["sequence"] > after and item["expiresAt"] > now]
        return dict(sessionId=session_id, ownerUid=session.owner_uid,
                    generation=session.vision_generation, cursor=session.safety_sequence,
                    events=events)
