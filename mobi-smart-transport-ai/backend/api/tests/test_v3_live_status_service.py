from app.schemas.v3_map import NearbyStop
from app.services import live_status_service


def test_board_coordinate_falls_back_to_approved_named_stop(monkeypatch) -> None:
    from app.api.routes import v3_bus

    monkeypatch.setattr(v3_bus, "_route_nodes", lambda **_: {})
    monkeypatch.setattr(
        live_status_service.nearby_stops_service,
        "find_named_stop",
        lambda **_: NearbyStop(
            stopId="1676",
            stopName="충북대학교중문",
            latitude=36.63363092,
            longitude=127.4604582,
            distanceMeters=263.7,
            source="PUBLIC_API",
        ),
    )

    board, alight = live_status_service._board_alight_coords(
        "20-1",
        "CJB270002900",
        "CJB283000216",
        None,
        None,
        None,
        None,
        None,
        "충북대학교중문",
        None,
        36.6359,
        127.4596,
    )

    assert board == (36.63363092, 127.4604582)
    assert alight is None
