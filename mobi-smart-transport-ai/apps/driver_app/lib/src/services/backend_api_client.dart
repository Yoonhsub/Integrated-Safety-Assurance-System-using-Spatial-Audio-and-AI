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

  Future<List<DriverRideRequestItem>> fetchDriverRideRequests() async {
    await Future<void>.delayed(const Duration(milliseconds: 300));

    return const [
      DriverRideRequestItem(
        passengerLabel: '시각 보조가 필요한 승객',
        boardingPointText: '중앙 정류장 인근',
        destinationText: '시청 방향',
        assistanceText: '탑승 위치 확인과 음성 안내가 필요한 mock 요청입니다.',
        statusLabel: '확인 대기',
      ),
    ];
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

class DriverRideRequestItem {
  const DriverRideRequestItem({
    required this.passengerLabel,
    required this.boardingPointText,
    required this.destinationText,
    required this.assistanceText,
    required this.statusLabel,
  });

  final String passengerLabel;
  final String boardingPointText;
  final String destinationText;
  final String assistanceText;
  final String statusLabel;
}