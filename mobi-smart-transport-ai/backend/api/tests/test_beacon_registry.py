import json
import pytest
from app.services.beacon_registry import BeaconRegistry


def test_registry_normalizes_mac_and_merges_route_labels(tmp_path):
    path = tmp_path / "registry.json"
    path.write_text(json.dumps([
        {"beaconId": "aa-bb-cc-dd-ee-01", "busId": "v", "routeNo": "502"},
        {"beaconId": "local-name", "busId": "v"},
        {"beaconId": "other", "busId": "other-v"},
    ]), encoding="utf-8")
    registry = BeaconRegistry.from_file(path)
    assert registry.resolve("local-name", "AA:BB:CC:DD:EE:01").route_no == "502"
    with pytest.raises(ValueError):
        registry.resolve("other", "AA:BB:CC:DD:EE:01")


@pytest.mark.parametrize("rows", [
    {}, [{"beaconId": "a", "busId": " "}],
    [{"beaconId": "a", "busId": "v", "routeNo": 502}],
    [{"beaconId": "a", "busId": "v", "extra": True}],
    [{"beaconId": "aa-bb-cc-dd-ee-01", "busId": "v"},
     {"beaconId": "AA:BB:CC:DD:EE:01", "busId": "other"}],
])
def test_invalid_registry_is_rejected(tmp_path, rows):
    path = tmp_path / "registry.json"
    path.write_text(json.dumps(rows), encoding="utf-8")
    with pytest.raises(ValueError):
        BeaconRegistry.from_file(path)
