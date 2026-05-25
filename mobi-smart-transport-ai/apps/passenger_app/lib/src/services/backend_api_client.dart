import 'dart:async';
import 'dart:convert';

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

Future<BusArrivalSummary> fetchBusArrivalSummary({
  required String stopId,
}) async {
  if (useMockData) {
    await Future<void>.delayed(const Duration(milliseconds: 250));

    return _mockBusArrivalSummary();
  }

  try {
    final response = await http
        .get(_buildUri('/bus-info/stops/$stopId/arrivals'))
        .timeout(timeout);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      return BusArrivalSummary(
        statusLabel: '연결 실패',
        description:
            '버스 도착 정보 API가 ${response.statusCode} 상태 코드를 반환했습니다.',
        semanticHint: '버스 도착 정보 API 응답 실패 상태를 표시하는 영역입니다.',
      );
    }

    final decodedBody = jsonDecode(response.body);

    if (decodedBody is! Map<String, dynamic>) {
      return const BusArrivalSummary(
        statusLabel: '응답 확인 필요',
        description: '버스 도착 정보 API 응답 형식이 예상과 다릅니다.',
        semanticHint: '버스 도착 정보 API 응답 형식 확인이 필요한 상태입니다.',
      );
    }

    final arrivals = decodedBody['arrivals'];

    if (arrivals is! List) {
      return const BusArrivalSummary(
        statusLabel: '응답 확인 필요',
        description: '버스 도착 정보 응답에 arrivals 목록이 없습니다.',
        semanticHint: '버스 도착 정보 목록 필드 확인이 필요한 상태입니다.',
      );
    }

    if (arrivals.isEmpty) {
      return const BusArrivalSummary(
        statusLabel: '도착 정보 없음',
        description: '현재 선택된 정류장에 표시할 버스 도착 정보가 없습니다.',
        semanticHint: '현재 정류장에 버스 도착 정보가 없는 상태입니다.',
      );
    }

    final arrivalSummaries = arrivals
        .whereType<Map<String, dynamic>>()
        .map((arrival) {
          final busNo = arrival['busNo']?.toString();
          final routeId = arrival['routeId']?.toString();
          final congestion = arrival['congestion']?.toString();

          if (busNo == null || busNo.isEmpty) {
            return null;
          }

          final details = <String>[
            if (routeId != null && routeId.isNotEmpty) '노선 $routeId',
            if (congestion != null && congestion.isNotEmpty) '혼잡도 $congestion',
          ];

          if (details.isEmpty) {
            return '$busNo번';
          }

          return '$busNo번(${details.join(', ')})';
        })
        .whereType<String>()
        .take(3)
        .toList();

    if (arrivalSummaries.isEmpty) {
      return BusArrivalSummary(
        statusLabel: '${arrivals.length}건 수신',
        description:
            '버스 도착 정보 ${arrivals.length}건을 수신했습니다. 표시 가능한 busNo 필드는 없으며, 세부 표시 필드는 API 계약 확정 후 확장합니다.',
        semanticHint: '버스 도착 정보 목록을 수신했지만 표시 가능한 버스 번호가 없는 상태입니다.',
      );
    }

    return BusArrivalSummary(
      statusLabel: '${arrivalSummaries.first} 도착 정보',
      description:
          '버스 도착 정보 ${arrivalSummaries.join(', ')}를 수신했습니다. 도착 시간, 남은 정류장, 저상버스 여부는 계약 확정 후 확장합니다.',
      semanticHint: '버스 번호, 노선, 혼잡도 기반 도착 정보를 표시하는 영역입니다.',
    );
  } on TimeoutException {
    return const BusArrivalSummary(
      statusLabel: '연결 시간 초과',
      description: '버스 도착 정보 API 연결 시간이 초과되었습니다.',
      semanticHint: '버스 도착 정보 API 연결 시간이 초과된 상태입니다.',
    );
  } catch (_) {
    return const BusArrivalSummary(
      statusLabel: '연결 실패',
      description: '버스 도착 정보 API에 연결할 수 없습니다.',
      semanticHint: '버스 도착 정보 API 연결 실패 상태를 표시하는 영역입니다.',
    );
  }
}

BusArrivalSummary _mockBusArrivalSummary() {
  return const BusArrivalSummary(
    statusLabel: 'mock 도착 정보',
    description:
        'mock 정류장 기준으로 502번, 713번 버스 도착 정보를 표시합니다. busNo, routeId, congestion은 확인된 응답 필드 기준으로 표시하며, 도착 시간과 저상버스 여부는 API 계약 확정 후 교체됩니다.',
    semanticHint: '실제 버스 도착 API 연동 전 mock 도착 정보를 표시하는 영역입니다.',
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

class BusArrivalSummary {
  const BusArrivalSummary({
    required this.statusLabel,
    required this.description,
    required this.semanticHint,
  });

  final String statusLabel;
  final String description;
  final String semanticHint;
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
