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
      final isAvailable =
          response.statusCode >= 200 && response.statusCode < 300;

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

  Future<DriverRideRequestsResult> fetchDriverRideRequests({
    required String driverId,
  }) async {
    if (useMockData) {
      await Future<void>.delayed(const Duration(milliseconds: 300));

      return const DriverRideRequestsResult(
        statusLabel: 'mock 요청 1건',
        description: 'mock 기사 기준 탑승 요청 1건을 표시합니다.',
        requests: [
          DriverRideRequestItem(
            requestLabel: '시각 보조가 필요한 승객',
            statusLabel: 'WAITING',
            description: '중앙 정류장에서 시청 방향 이동을 요청한 mock 탑승 요청입니다.',
            semanticHint: 'mock 탑승 요청 카드입니다.',
          ),
        ],
      );
    }

    try {
      final response = await http
          .get(_buildUri('/drivers/$driverId/ride-requests'))
          .timeout(timeout);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        return DriverRideRequestsResult(
          statusLabel: '조회 실패',
          description:
              '기사 탑승 요청 목록 API가 ${response.statusCode} 상태 코드를 반환했습니다.',
          requests: const [],
        );
      }

      final decodedBody = jsonDecode(response.body);

      if (decodedBody is! Map<String, dynamic>) {
        return const DriverRideRequestsResult(
          statusLabel: '응답 확인 필요',
          description: '기사 탑승 요청 목록 API 응답 형식이 예상과 다릅니다.',
          requests: [],
        );
      }

      final requests = decodedBody['requests'];

      if (requests is! List) {
        return const DriverRideRequestsResult(
          statusLabel: '응답 확인 필요',
          description: '기사 탑승 요청 목록 응답에 requests 목록이 없습니다.',
          requests: [],
        );
      }

      if (requests.isEmpty) {
        return const DriverRideRequestsResult(
          statusLabel: '요청 없음',
          description: '현재 배정된 탑승 요청이 없습니다.',
          requests: [],
        );
      }

      final requestItems = requests
          .whereType<Map<String, dynamic>>()
          .map((request) {
            final requestId = request['requestId']?.toString();
            final userId = request['userId']?.toString();
            final stopId = request['stopId']?.toString();
            final routeId = request['routeId']?.toString();
            final busNo = request['busNo']?.toString();
            final status = request['status']?.toString();

            final title = requestId == null || requestId.isEmpty
                ? '탑승 요청'
                : '탑승 요청 $requestId';

            final details = <String>[
              if (userId != null && userId.isNotEmpty) '승객 $userId',
              if (stopId != null && stopId.isNotEmpty) '정류장 $stopId',
              if (routeId != null && routeId.isNotEmpty) '노선 $routeId',
              if (busNo != null && busNo.isNotEmpty) '버스 $busNo',
            ];

            return DriverRideRequestItem(
              requestLabel: title,
              statusLabel:
                  status == null || status.isEmpty ? '상태 확인 필요' : status,
              description: details.isEmpty
                  ? '탑승 요청 세부 정보는 응답 계약 확정 후 표시합니다.'
                  : details.join(', '),
              semanticHint: '기사 앱 탑승 요청 목록에 표시되는 요청 카드입니다.',
            );
          })
          .take(5)
          .toList();

      if (requestItems.isEmpty) {
        return DriverRideRequestsResult(
          statusLabel: '${requests.length}건 수신',
          description:
              '탑승 요청 ${requests.length}건을 수신했지만 표시 가능한 요청 정보가 없습니다.',
          requests: const [],
        );
      }

      return DriverRideRequestsResult(
        statusLabel: '${requestItems.length}건 수신',
        description: '기사에게 배정된 탑승 요청 ${requestItems.length}건을 표시합니다.',
        requests: requestItems,
      );
    } on TimeoutException {
      return const DriverRideRequestsResult(
        statusLabel: '조회 시간 초과',
        description: '기사 탑승 요청 목록 API 연결 시간이 초과되었습니다.',
        requests: [],
      );
    } catch (_) {
      return const DriverRideRequestsResult(
        statusLabel: '조회 실패',
        description: '기사 탑승 요청 목록 API에 연결할 수 없습니다.',
        requests: [],
      );
    }
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

class DriverRideRequestsResult {
  const DriverRideRequestsResult({
    required this.statusLabel,
    required this.description,
    required this.requests,
  });

  final String statusLabel;
  final String description;
  final List<DriverRideRequestItem> requests;
}

class DriverRideRequestItem {
  const DriverRideRequestItem({
    required this.requestLabel,
    required this.statusLabel,
    required this.description,
    required this.semanticHint,
  });

  final String requestLabel;
  final String statusLabel;
  final String description;
  final String semanticHint;
}