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