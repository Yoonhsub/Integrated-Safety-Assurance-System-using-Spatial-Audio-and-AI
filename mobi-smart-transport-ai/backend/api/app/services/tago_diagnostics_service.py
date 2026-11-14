"""Bounded, live-only diagnostics. Never reads Firebase or mock providers."""
from datetime import datetime, timezone
import re
import httpx
from app.schemas.tago_diagnostics import TagoArrivalRecord, TagoLocationRecord, TagoDiagnosticResponse
from services.public_data.public_data_client.data_go_kr_client import DataGoKrClient
from services.public_data.public_data_client.exceptions import PublicDataNetworkError, PublicDataServiceKeyMissingError

PATHS = {
    "arrivals": "/1613000/ArvlInfoInqireService/getSttnAcctoArvlPrearngeInfoList",
    "locations": "/1613000/BusLcInfoInqireService/getRouteAcctoBusLcList",
}

class ProviderRejected(ValueError):
    pass

def optional_text(value):
    return str(value).strip() or None if isinstance(value, (str, int)) and not isinstance(value, bool) else None

def optional_count(value):
    if isinstance(value, bool) or not re.fullmatch(r"[0-9]+", str(value)):
        return None
    return int(value)

def parse_items(payload):
    response = payload["response"]
    header = response["header"]
    if not isinstance(header, dict) or "resultCode" not in header:
        raise ValueError("Missing result code")
    if str(header["resultCode"]) not in {"00", "0"}:
        raise ProviderRejected()
    body = response["body"]
    total = optional_count(body.get("totalCount"))
    items = body.get("items")
    if items in (None, "", {}):
        if total != 0:
            raise ValueError("Empty payload without zero totalCount")
        return [], total
    records = items.get("item", [])
    if isinstance(records, dict):
        records = [records]
    if not isinstance(records, list) or any(not isinstance(x, dict) for x in records):
        raise ValueError("Invalid records")
    if not records and total != 0:
        raise ValueError("Missing records")
    if total is not None and total < len(records):
        raise ValueError("Inconsistent totalCount")
    return records[:100], total

class TagoDiagnosticsService:
    def fetch(self, kind: str, city_code: str, identifier: str) -> TagoDiagnosticResponse:
        if kind not in PATHS or not re.fullmatch(r"[0-9]{1,6}", city_code) or not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", identifier):
            raise ValueError("Invalid diagnostic query")
        context = dict(cityCode=city_code, **({"stopId": identifier} if kind == "arrivals" else {"routeId": identifier}))
        fetched_at = None
        try:
            # Fixed official origin: callers cannot redirect server credentials.
            with DataGoKrClient(base_url="https://apis.data.go.kr", city_code=city_code, timeout=10.0) as client:
                response = client.get(PATHS[kind], params={"cityCode": city_code,
                    "nodeId" if kind == "arrivals" else "routeId": identifier,
                    "_type": "json", "numOfRows": "100", "pageNo": "1"})
                fetched_at = datetime.now(timezone.utc)
                rows, total = parse_items(response.json())
            if kind == "arrivals":
                records = [TagoArrivalRecord(routeId=optional_text(x.get("routeid")),
                    routeNo=optional_text(x.get("routeno")), arrivalSeconds=optional_count(x.get("arrtime")),
                    remainingStops=optional_count(x.get("arrprevstationcnt")), vehicleType=optional_text(x.get("vehicletp"))) for x in rows]
                if any(r.routeId is None and r.routeNo is None for r in records):
                    raise ValueError("Unrecognized arrival record")
            else:
                records = [TagoLocationRecord(busId=optional_text(x.get("vehicleno")),
                    nodeId=optional_text(x.get("nodeid")), nodeName=optional_text(x.get("nodenm"))) for x in rows]
                if any(r.nodeId is None and r.nodeName is None for r in records):
                    raise ValueError("Unrecognized location record")
            return TagoDiagnosticResponse(**context, source="PUBLIC_API", status="SUCCESS" if records else "EMPTY",
                records=records, fetchedAt=fetched_at, totalCount=total, truncated=total is not None and total > len(records))
        except PublicDataServiceKeyMissingError:
            error = "SERVICE_KEY_MISSING"
        except PublicDataNetworkError as exc:
            error = "UPSTREAM_TIMEOUT" if isinstance(exc.__cause__, httpx.TimeoutException) else "UPSTREAM_UNAVAILABLE"
        except ProviderRejected:
            error = "PROVIDER_REJECTED"
        except (ValueError, KeyError, TypeError, AttributeError):
            error = "MALFORMED_RESPONSE"
        # Never return raw exception/provider text or URLs carrying a service key.
        return TagoDiagnosticResponse(**context, source="ERROR", status="ERROR", errorCode=error, fetchedAt=fetched_at)
