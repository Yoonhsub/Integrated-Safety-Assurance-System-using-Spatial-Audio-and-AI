"""Optional, server-owned beacon-to-vehicle assignments loaded at startup."""
from __future__ import annotations

import json
import os
import re
from dataclasses import dataclass
from pathlib import Path

from dotenv import load_dotenv


def normalize_beacon_id(value: str) -> str:
    value = value.strip()
    if re.fullmatch(r"[0-9a-fA-F]{2}([:-][0-9a-fA-F]{2}){5}", value):
        return value.replace("-", ":").upper()
    return value


@dataclass(frozen=True)
class BeaconAssignment:
    bus_id: str
    route_no: str | None = None


class BeaconRegistry:
    def __init__(self, entries: dict[str, BeaconAssignment] | None = None, *, configured: bool = False):
        self._entries = dict(entries or {})
        self.configured = configured

    @classmethod
    def from_file(cls, path: Path) -> "BeaconRegistry":
        data = json.loads(path.read_text(encoding="utf-8-sig"))
        if not isinstance(data, list):
            raise ValueError("Beacon registry must be a JSON array")
        entries: dict[str, BeaconAssignment] = {}
        for row in data:
            if not isinstance(row, dict) or set(row) - {"beaconId", "busId", "routeNo"}:
                raise ValueError("Invalid beacon registry entry")
            for name in ("beaconId", "busId"):
                if not isinstance(row.get(name), str) or not row[name].strip():
                    raise ValueError(f"Beacon registry requires a nonblank {name}")
            route = row.get("routeNo")
            if route is not None and (not isinstance(route, str) or not route.strip()):
                raise ValueError("routeNo must be a nonblank string or null")
            key = normalize_beacon_id(row["beaconId"])
            if key in entries:
                raise ValueError(f"Duplicate beacon assignment: {key}")
            entries[key] = BeaconAssignment(row["busId"].strip(), route.strip() if route else None)
        return cls(entries, configured=True)

    def resolve(self, beacon_id: str, mac_address: str | None = None) -> BeaconAssignment | None:
        by_id = self._entries.get(normalize_beacon_id(beacon_id))
        by_mac = self._entries.get(normalize_beacon_id(mac_address)) if mac_address else None
        if by_id and by_mac:
            if by_id.bus_id != by_mac.bus_id or (
                by_id.route_no and by_mac.route_no and by_id.route_no != by_mac.route_no
            ):
                raise ValueError("beaconId and macAddress identify different vehicle assignments")
            return BeaconAssignment(by_id.bus_id, by_id.route_no or by_mac.route_no)
        return by_id or by_mac


def _load_registry() -> BeaconRegistry:
    project_root = Path(__file__).resolve().parents[4]
    load_dotenv(project_root / ".env", override=False)
    configured_path = os.getenv("BEACON_REGISTRY_PATH", "").strip()
    if not configured_path:
        return BeaconRegistry()
    path = Path(configured_path).expanduser()
    if not path.is_absolute():
        path = project_root / path
    return BeaconRegistry.from_file(path)


beacon_registry = _load_registry()
