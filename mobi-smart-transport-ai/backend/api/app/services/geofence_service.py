from app.schemas.geofence import GeofenceCheckRequest, GeofenceCheckResponse, GeofenceStatus


class GeofenceService:
    """지오펜싱 판별 서비스 skeleton.

    TODO(심현석):
    - Firebase에서 stopId 기준 safeZone/warningZones/dangerZones 조회
    - polygon 내부 판별 구현
    - 사용자별 이전 상태 저장/상태 전이 구현
    - DANGER/WARNING 발생 시 FCM 이벤트 연동
    """

    def check(self, payload: GeofenceCheckRequest) -> GeofenceCheckResponse:
        # 의도적 stub: 현재 좌표가 입력되었다는 사실만 검증하고 SAFE 반환.
        return GeofenceCheckResponse(
            status=GeofenceStatus.UNKNOWN,
            message="지오펜싱 알고리즘은 아직 구현되지 않았습니다. 심현석 담당 섹션에서 완성해야 합니다.",
            shouldSpeak=False,
            shouldVibrate=False,
            eventId=None,
        )
