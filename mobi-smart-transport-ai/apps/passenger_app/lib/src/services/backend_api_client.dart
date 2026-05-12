class BackendApiClient {
  const BackendApiClient({required this.baseUrl});

  final String baseUrl;

  Future<PassengerHomeSnapshot> fetchPassengerHomeSnapshot() async {
    await Future<void>.delayed(const Duration(milliseconds: 400));

    return const PassengerHomeSnapshot(
      safetyStatus: PassengerStatusItem(
        statusLabel: '안전 확인 중',
        description:
            '현재 위치 기반 안전 상태 mock 값을 표시 중이며, geofence API 계약 확정 후 실제 값으로 교체됩니다.',
        semanticHint: 'geofence check API 연결 전 mock 안전 상태입니다.',
      ),
      busArrivalStatus: PassengerStatusItem(
        statusLabel: 'mock 도착 정보',
        description:
            '가까운 정류장의 버스 도착 정보 mock 값을 표시 중이며, 공공데이터 mock 기준 확정 후 실제 값으로 교체됩니다.',
        semanticHint: 'bus info arrivals API 연결 전 mock 버스 도착 정보입니다.',
      ),
      rideRequestStatus: PassengerStatusItem(
        statusLabel: '요청 전',
        description:
            '탑승 요청 mock 상태를 표시 중이며, rideRequests 파이프라인 확정 후 실제 요청 상태로 교체됩니다.',
        semanticHint: 'ride requests API 연결 전 mock 탑승 요청 상태입니다.',
      ),
    );
  }
}

class PassengerHomeSnapshot {
  const PassengerHomeSnapshot({
    required this.safetyStatus,
    required this.busArrivalStatus,
    required this.rideRequestStatus,
  });

  final PassengerStatusItem safetyStatus;
  final PassengerStatusItem busArrivalStatus;
  final PassengerStatusItem rideRequestStatus;
}

class PassengerStatusItem {
  const PassengerStatusItem({
    required this.statusLabel,
    required this.description,
    required this.semanticHint,
  });

  final String statusLabel;
  final String description;
  final String semanticHint;
}
