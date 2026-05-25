class BackendApiClient {
  const BackendApiClient({
    required this.baseUrl,
    this.useMockData = true,
    this.timeout = const Duration(seconds: 5),
  });

  final String baseUrl;
  final bool useMockData;
  final Duration timeout;

  Future<BackendHealthStatus> fetchHealthStatus() async {
    await Future<void>.delayed(const Duration(milliseconds: 200));

    if (useMockData) {
      return const BackendHealthStatus(
        isAvailable: true,
        message: 'mock 백엔드 연결 상태를 확인했습니다.',
      );
    }

    return const BackendHealthStatus(
      isAvailable: false,
      message: '실제 /health API 연결은 후속 섹션에서 확인합니다.',
    );
  }

  Future<PassengerHomeSnapshot> fetchPassengerHomeSnapshot() async {
    await Future<void>.delayed(const Duration(milliseconds: 400));

    return const PassengerHomeSnapshot(
      safetyStatus: PassengerStatusItem(
        statusLabel: '안전 확인 중',
        description: '현재 위치 기반 안전 상태 mock 값을 표시 중이며, geofence API 계약 확정 후 실제 값으로 교체됩니다.',
        semanticHint: '실제 geofence API 연동 전 mock 안전 상태를 표시하는 영역입니다.',
      ),
      busArrivalStatus: PassengerStatusItem(
        statusLabel: 'mock 도착 정보',
        description: '가까운 정류장의 버스 도착 정보 mock 값을 표시 중이며, 공공데이터 mock 기준 확정 후 실제 값으로 교체됩니다.',
        semanticHint: '실제 버스 도착 API 연동 전 mock 도착 정보를 표시하는 영역입니다.',
      ),
      rideRequestStatus: PassengerStatusItem(
        statusLabel: '요청 전',
        description: '탑승 요청 mock 상태를 표시 중이며, rideRequests 파이프라인 확정 후 실제 요청 상태로 교체됩니다.',
        semanticHint: '실제 탑승 요청 API 연동 전 mock 요청 상태를 표시하는 영역입니다.',
      ),
    );
  }
}

class BackendHealthStatus {
  const BackendHealthStatus({
    required this.isAvailable,
    required this.message,
  });

  final bool isAvailable;
  final String message;
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
