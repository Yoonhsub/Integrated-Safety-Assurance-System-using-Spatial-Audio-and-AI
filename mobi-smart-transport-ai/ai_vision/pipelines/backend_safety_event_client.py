"""HTTP transport for sending AI Vision interpretations to the MOBI backend."""
from __future__ import annotations

from dataclasses import dataclass
from typing import Any
from urllib.parse import urlsplit

import httpx

from ai_vision.pipelines.safety_interpreter import SafetyInterpretation


TRANSPORT_SCHEMA_VERSION = "1.0.0"
INGEST_PATH = "/ai-vision/events"
RECENT_EVENTS_PATH = "/safety-events/recent"
_INTERPRETATION_STATUSES = {"event", "no_event", "unavailable", "error"}


class BackendSafetyEventClientError(RuntimeError):
    """Base class for backend transport failures."""


class BackendConnectionError(BackendSafetyEventClientError):
    """The backend could not be reached."""


class BackendRequestTimeout(BackendSafetyEventClientError):
    """The backend request exceeded its configured timeout."""


class BackendHTTPError(BackendSafetyEventClientError):
    """The backend returned an unexpected non-success HTTP status."""

    def __init__(self, status_code: int, body: str) -> None:
        super().__init__(f"Backend returned HTTP {status_code}: {body}")
        self.status_code = status_code
        self.body = body


class BackendValidationError(BackendHTTPError):
    """The backend rejected the transport request (HTTP 4xx)."""


class BackendServerError(BackendHTTPError):
    """The backend failed while handling the transport request (HTTP 5xx)."""


class BackendInvalidResponse(BackendSafetyEventClientError):
    """The backend response did not match the ingestion response contract."""


class InvalidTransportInput(BackendSafetyEventClientError):
    """The local interpretation cannot be serialized to the transport contract."""


@dataclass(frozen=True)
class BackendSafetyEventOutcome:
    status: str
    stored: bool
    event_id: str | None


def serialize_interpretation(interpretation: SafetyInterpretation) -> dict[str, Any]:
    """Serialize only transport fields; detections and image data are excluded."""
    status = _value(getattr(interpretation, "status", None))
    if status not in _INTERPRETATION_STATUSES:
        raise InvalidTransportInput(f"Unsupported interpretation status: {status!r}.")

    source = _required_text(getattr(interpretation, "source", None), "source")
    payload: dict[str, Any] = {
        "schemaVersion": TRANSPORT_SCHEMA_VERSION,
        "status": status,
        "source": source,
    }
    frame_id = getattr(interpretation, "frame_id", None)
    captured_at = getattr(interpretation, "captured_at", None)
    if frame_id is not None:
        payload["frameId"] = str(frame_id)
    if captured_at is not None:
        payload["capturedAt"] = _required_text(captured_at, "capturedAt")

    event = getattr(interpretation, "event", None)
    error = getattr(interpretation, "error", None)
    if status == "event":
        if event is None:
            raise InvalidTransportInput("event status requires a Safety Event.")
        try:
            model = event.model_info
            payload.update(
                {
                    "eventId": _required_text(event.event_id, "eventId"),
                    "frameId": _required_text(event.frame_id, "frameId"),
                    "capturedAt": _required_text(event.captured_at, "capturedAt"),
                    "riskLevel": _required_text(event.risk_level, "riskLevel"),
                    "reason": _required_text(event.reason, "reason"),
                    "primaryClass": _required_text(event.primary_class, "primaryClass"),
                    "confidence": event.confidence,
                    "message": _required_text(event.message, "message"),
                    "modelInfo": {
                        "provider": _required_text(model.provider, "modelInfo.provider"),
                        "name": _required_text(model.name, "modelInfo.name"),
                    },
                }
            )
            if model.version is not None:
                payload["modelInfo"]["version"] = _required_text(
                    model.version,
                    "modelInfo.version",
                )
        except AttributeError as exc:
            raise InvalidTransportInput(
                "Safety Event is missing required transport fields or modelInfo."
            ) from exc
        if isinstance(event.confidence, bool) or not isinstance(event.confidence, (int, float)):
            raise InvalidTransportInput("confidence must be numeric.")
        if not 0 <= event.confidence <= 1:
            raise InvalidTransportInput("confidence must be in [0, 1].")
        if error is not None:
            raise InvalidTransportInput("event status cannot contain inference error details.")
    elif status == "no_event":
        if event is not None or error is not None:
            raise InvalidTransportInput("no_event cannot contain event or error details.")
        if "frameId" not in payload or "capturedAt" not in payload:
            raise InvalidTransportInput("no_event requires frameId and capturedAt.")
    else:
        if event is not None:
            raise InvalidTransportInput(f"{status} status cannot contain a Safety Event.")
        if error is None:
            raise InvalidTransportInput(f"{status} status requires inference error details.")
        try:
            payload["error"] = {
                "code": _required_text(error.code, "error.code"),
                "message": _required_text(error.message, "error.message"),
            }
        except AttributeError as exc:
            raise InvalidTransportInput(
                f"{status} status requires error code and message."
            ) from exc
    return payload


class BackendSafetyEventClient:
    """Send interpretations to a configured backend URL, with no retry/fallback."""

    def __init__(
        self,
        backend_url: str,
        *,
        timeout: float = 5.0,
        transport: httpx.BaseTransport | None = None,
    ) -> None:
        parsed = urlsplit(backend_url)
        if parsed.scheme not in {"http", "https"} or not parsed.netloc:
            raise ValueError("backend_url must be an absolute HTTP or HTTPS URL.")
        if timeout <= 0:
            raise ValueError("timeout must be greater than zero.")
        self.backend_url = backend_url.rstrip("/")
        self._client = httpx.Client(
            base_url=self.backend_url,
            timeout=timeout,
            transport=transport,
        )

    def send(self, interpretation: SafetyInterpretation) -> BackendSafetyEventOutcome:
        payload = serialize_interpretation(interpretation)
        response = self._request("POST", INGEST_PATH, json=payload)
        expected_http_status = 201 if payload["status"] == "event" else 200
        if response.status_code != expected_http_status:
            raise BackendInvalidResponse(
                f"HTTP {response.status_code} is inconsistent with interpretation "
                f"status {payload['status']!r}; expected {expected_http_status}."
            )
        return self._parse_ingest_response(response, expected_status=payload["status"])

    def recent_events(self, *, limit: int = 20) -> list[dict[str, Any]]:
        if not 1 <= limit <= 100:
            raise ValueError("limit must be between 1 and 100.")
        response = self._request("GET", RECENT_EVENTS_PATH, params={"limit": limit})
        if response.status_code != 200:
            raise BackendInvalidResponse(
                f"Recent events endpoint returned unexpected HTTP {response.status_code}."
            )
        try:
            body = response.json()
        except ValueError as exc:
            raise BackendInvalidResponse("Recent events response is not valid JSON.") from exc
        events = body.get("events") if isinstance(body, dict) else None
        if not isinstance(events, list) or any(not isinstance(item, dict) for item in events):
            raise BackendInvalidResponse("Recent events response must contain an events array.")
        return events

    def close(self) -> None:
        self._client.close()

    def __enter__(self) -> BackendSafetyEventClient:
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    def _request(self, method: str, path: str, **kwargs: Any) -> httpx.Response:
        try:
            response = self._client.request(method, path, **kwargs)
        except httpx.TimeoutException as exc:
            raise BackendRequestTimeout(f"Backend request timed out: {exc}") from exc
        except httpx.ConnectError as exc:
            raise BackendConnectionError(f"Could not connect to backend: {exc}") from exc
        except httpx.RequestError as exc:
            raise BackendConnectionError(f"Backend transport failed: {exc}") from exc

        if 400 <= response.status_code < 500:
            raise BackendValidationError(response.status_code, response.text)
        if 500 <= response.status_code < 600:
            raise BackendServerError(response.status_code, response.text)
        return response

    @staticmethod
    def _parse_ingest_response(
        response: httpx.Response,
        *,
        expected_status: str,
    ) -> BackendSafetyEventOutcome:
        try:
            body = response.json()
        except ValueError as exc:
            raise BackendInvalidResponse("Ingestion response is not valid JSON.") from exc
        if not isinstance(body, dict):
            raise BackendInvalidResponse("Ingestion response must be a JSON object.")

        status = body.get("status")
        stored = body.get("stored")
        record = body.get("safetyEvent")
        if status != expected_status or not isinstance(stored, bool):
            raise BackendInvalidResponse("Ingestion response status/stored fields are invalid.")
        if status == "event":
            if stored is not True or not isinstance(record, dict):
                raise BackendInvalidResponse("Stored event response must include safetyEvent.")
            event_id = record.get("eventId")
            if not isinstance(event_id, str) or not event_id.strip():
                raise BackendInvalidResponse("Stored safetyEvent must include eventId.")
            return BackendSafetyEventOutcome(status=status, stored=True, event_id=event_id)
        if stored is not False or record is not None:
            raise BackendInvalidResponse(
                "Non-event response must declare stored=false and safetyEvent=null."
            )
        return BackendSafetyEventOutcome(status=status, stored=False, event_id=None)


def _value(value: Any) -> Any:
    return getattr(value, "value", value)


def _required_text(value: Any, field_name: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise InvalidTransportInput(f"{field_name} must be a non-blank string.")
    return value
