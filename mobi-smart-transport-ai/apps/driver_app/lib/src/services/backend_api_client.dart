import 'dart:async';

import 'package:http/http.dart' as http;

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
    if (useMockData) {
      await Future<void>.delayed(const Duration(milliseconds: 200));

      return const BackendHealthStatus(
        isAvailable: true,
        message: 'mock 백엔드 연결 상태를 확인했습니다.',
      );
    }

    try {
      final response = await http.get(_buildUri('/health')).timeout(timeout);
      final isAvailable = response.statusCode >= 200 && response.statusCode < 300;

      return BackendHealthStatus(
        isAvailable: isAvailable,
        message: isAvailable
            ? '실제 /health API 연결에 성공했습니다.'
            : '실제 /health API가 ${response.statusCode} 상태 코드를 반환했습니다.',
      );
    } on TimeoutException {
      return const BackendHealthStatus(
        isAvailable: false,
        message: '백엔드 /health API 연결 시간이 초과되었습니다.',
      );
    } catch (_) {
      return const BackendHealthStatus(
        isAvailable: false,
        message: '백엔드 /health API에 연결할 수 없습니다.',
      );
    }
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

  Uri _buildUri(String path) {
    final normalizedBaseUrl = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;

    return Uri.parse('$normalizedBaseUrl$path');
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