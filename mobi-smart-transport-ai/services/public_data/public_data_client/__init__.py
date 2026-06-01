"""김도성 담당 services/public_data 영역의 공개 API.

외부 호출자(현재는 동일 영역 내부 사용 예시, 향후 심현석 백엔드)는 다음 import만 사용한다.

    from public_data_client import (
        BusArrivalsService,
        CongestionLevel,
        NormalizedBusArrival,
        NormalizedBusArrivalsResponse,
        PublicDataError,
        PublicDataServiceKeyMissingError,
        PublicDataNetworkError,
        PublicDataEmptyResponseError,
    )

내부 transport 계층(``DataGoKrClient``)도 ``public_data_client.DataGoKrClient``로 임포트
가능하지만, 호출자 측에서 직접 사용을 권장하지 않는다.
"""

from .bus_arrivals_service import (
    BusArrivalsService,
    LiveBusArrivalsProvider,
    MockBusArrivalsProvider,
)
from .bus_location_service import BusLocationService
from .bus_route_service import BusRouteService
from .data_go_kr_client import DataGoKrClient
from .exceptions import (
    PublicDataEmptyResponseError,
    PublicDataError,
    PublicDataNetworkError,
    PublicDataServiceKeyMissingError,
)
from .low_floor_filter import (
    AccessibilityMode,
    apply_accessibility_filter,
    filter_accessible_arrivals,
    filter_low_floor_only,
    is_accessible,
    prioritize_low_floor,
    sort_by_accessibility,
)
from .normalize import (
    map_reride_to_congestion,
    map_vehicle_type_to_low_floor,
    seconds_to_arrival_minutes,
)
from .schemas import (
    CongestionLevel,
    NormalizedBusArrival,
    NormalizedBusArrivalsResponse,
)

__all__ = [
    # Public API
    "BusArrivalsService",
    "NormalizedBusArrival",
    "NormalizedBusArrivalsResponse",
    "NormalizedBusLocation",
    "NormalizedBusLocationResponse",
    "NormalizedBusRouteNode",
    "NormalizedBusRouteStopsResponse",
    "CongestionLevel",
    # Accessibility filter / sort (V2 신규)
    "AccessibilityMode",
    "apply_accessibility_filter",
    "filter_accessible_arrivals",
    "sort_by_accessibility",
    "is_accessible",
    # V1 하위 호환 (V2 신규 사용 권장)
    "prioritize_low_floor",
    "filter_low_floor_only",
    # Normalize helpers (단위 테스트와 다른 provider 구현이 재사용)
    "map_vehicle_type_to_low_floor",
    "map_reride_to_congestion",
    "seconds_to_arrival_minutes",
    # Exceptions
    "PublicDataError",
    "PublicDataServiceKeyMissingError",
    "PublicDataNetworkError",
    "PublicDataEmptyResponseError",
    # Lower-level (transport / providers) — 내부용 노출이지만 디버깅을 위해 export
    "DataGoKrClient",
    "BusLocationService",
    "BusRouteService",
    "MockBusArrivalsProvider",
    "LiveBusArrivalsProvider",
]
