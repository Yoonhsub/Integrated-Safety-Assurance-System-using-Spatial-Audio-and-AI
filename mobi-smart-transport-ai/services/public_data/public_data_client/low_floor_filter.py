from .schemas import NormalizedBusArrival


def prioritize_low_floor(arrivals: list[NormalizedBusArrival]) -> list[NormalizedBusArrival]:
    """저상버스를 우선 표시하도록 정렬한다.

    TODO(김도성): 실제 API 필드가 확정되면 lowFloor normalize 로직을 보강한다.
    """
    return sorted(arrivals, key=lambda item: (not item.lowFloor, item.arrivalMinutes))
