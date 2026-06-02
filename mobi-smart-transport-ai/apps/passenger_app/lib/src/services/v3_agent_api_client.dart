import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/v3_guidance_models.dart';
import 'converse_live.dart';

class V3ApiException implements Exception {
  const V3ApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() {
    if (statusCode == null) return message;
    return '$message (HTTP $statusCode)';
  }
}

class V3HealthStatus {
  const V3HealthStatus({required this.isAvailable, required this.message});

  final bool isAvailable;
  final String message;
}

class V3AgentApiClient {
  const V3AgentApiClient({
    required this.baseUrl,
    this.timeout = const Duration(seconds: 60),
    http.Client? httpClient,
  }) : _httpClient = httpClient;

  static const Duration _converseTimeout = Duration(seconds: 45);

  final String baseUrl;
  final Duration timeout;
  final http.Client? _httpClient;

  Future<V3HealthStatus> fetchHealth() async {
    try {
      final response = await _client.get(_buildUri('/health')).timeout(timeout);
      final ok = response.statusCode >= 200 && response.statusCode < 300;
      return V3HealthStatus(
        isAvailable: ok,
        message: ok ? '백엔드 연결 성공' : '백엔드가 ${response.statusCode}를 반환했어.',
      );
    } on TimeoutException {
      return const V3HealthStatus(
          isAvailable: false, message: '백엔드 연결 시간이 초과됐어.');
    } catch (_) {
      return const V3HealthStatus(
          isAvailable: false, message: '백엔드에 연결할 수 없어.');
    }
  }

  Future<V3GuidanceState> createSession({
    required String sessionId,
    required String wakeWord,
  }) async {
    final json = await _postJson('/guidance/session', <String, Object?>{
      'sessionId': sessionId,
      'wakeWord': wakeWord,
    });
    return V3GuidanceState.fromJson(json);
  }

  Future<V3GuidanceState> fetchState({required String sessionId}) async {
    final json = await _getJson('/guidance/state', <String, String>{
      'sessionId': sessionId,
    });
    return V3GuidanceState.fromJson(json);
  }

  Future<V3GuidanceState> resetSession({required String sessionId}) async {
    final json = await _postJson('/guidance/reset', <String, Object?>{
      'sessionId': sessionId,
      'event': 'RESET',
      'payload': <String, Object?>{},
    });
    return V3GuidanceState.fromJson(json);
  }

  Future<V3GuidanceState> applyGuidanceEvent({
    required String sessionId,
    required String event,
    Map<String, Object?> payload = const <String, Object?>{},
  }) async {
    final json = await _postJson('/guidance/event', <String, Object?>{
      'sessionId': sessionId,
      'event': event,
      'payload': payload,
    });
    return V3GuidanceState.fromJson(json);
  }

  Future<V3AgentResponse> converse({
    required String sessionId,
    required String wakeWord,
    required String utterance,
    String? mode,
    double? originLat,
    double? originLng,
  }) async {
    final json = await _postJson(
        '/agent/converse',
        <String, Object?>{
          'sessionId': sessionId,
          'wakeWord': wakeWord,
          'utterance': utterance,
          if (mode != null) 'mode': mode,
          if (originLat != null && originLng != null) 'originLat': originLat,
          if (originLat != null && originLng != null) 'originLng': originLng,
        },
        customTimeout: _converseTimeout);
    return V3AgentResponse.fromJson(json);
  }

  /// 처리 단계 'thought'를 실시간 스트리밍하고 마지막에 최종 응답을 주는 WS 스트림.
  /// 웹에서만 동작하며, 실패 시 호출자가 [converse]로 폴백한다.
  Stream<ConverseEvent> converseLive({
    required String sessionId,
    required String wakeWord,
    required String utterance,
    String? mode,
    double? originLat,
    double? originLng,
  }) {
    return openConverseLive(
      baseUrl: baseUrl,
      request: <String, Object?>{
        'sessionId': sessionId,
        'wakeWord': wakeWord,
        'utterance': utterance,
        if (mode != null) 'mode': mode,
        if (originLat != null && originLng != null) 'originLat': originLat,
        if (originLat != null && originLng != null) 'originLng': originLng,
      },
    );
  }

  Future<Uint8List> synthesizeSpeech({required String text}) async {
    try {
      final response = await _client
          .post(
            _buildUri('/agent/tts'),
            headers: const <String, String>{'Content-Type': 'application/json'},
            body: jsonEncode(<String, Object?>{'text': text}),
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw V3ApiException(
          'Gemini TTS를 사용할 수 없어.',
          statusCode: response.statusCode,
        );
      }
      return response.bodyBytes;
    } on TimeoutException {
      throw const V3ApiException('Gemini TTS 연결 시간이 초과됐어.');
    } on V3ApiException {
      rethrow;
    } catch (_) {
      throw const V3ApiException('Gemini TTS에 연결할 수 없어.');
    }
  }

  Future<V3RouteRecommendResponse> routeRecommend({
    required String destination,
    double? originLat,
    double? originLng,
    String? mode,
  }) async {
    final query = <String, String>{
      'destination': destination,
    };
    if (originLat != null && originLng != null) {
      query['originLat'] = originLat.toString();
      query['originLng'] = originLng.toString();
    }
    if (mode != null) {
      query['mode'] = mode;
    }
    final json = await _getJson('/bus/route-recommend', query);
    return V3RouteRecommendResponse.fromJson(json);
  }

  Future<V3RoutePlanResponse> routePlan({
    required String q,
    double? originLat,
    double? originLng,
    String? mode,
  }) async {
    final query = <String, String>{
      'q': q,
    };
    if (originLat != null && originLng != null) {
      query['originLat'] = originLat.toString();
      query['originLng'] = originLng.toString();
    }
    if (mode != null) {
      query['mode'] = mode;
    }
    final json = await _getJson('/bus/route-plan', query);
    return V3RoutePlanResponse.fromJson(json);
  }

  Future<V3BusArrivalsResponse> arrivals({
    required String stopId,
    String? routeNo,
    String? mode,
  }) async {
    final query = <String, String>{'stopId': stopId};
    if (routeNo != null && routeNo.trim().isNotEmpty) {
      query['routeNo'] = routeNo.trim();
    }
    if (mode != null) {
      query['mode'] = mode;
    }
    final json = await _getJson('/bus/arrivals', query);
    return V3BusArrivalsResponse.fromJson(json);
  }

  Future<V3LiveRouteStatusResponse> liveRouteStatus({
    required String routeNo,
    required String routeId,
    required String boardStopId,
    required String alightStopId,
    double? userLat,
    double? userLng,
    double? boardLat,
    double? boardLng,
    double? alightLat,
    double? alightLng,
    String? mode,
  }) async {
    final query = <String, String>{
      'routeNo': routeNo,
      'routeId': routeId,
      'boardStopId': boardStopId,
      'alightStopId': alightStopId,
    };
    _addCoordinatePair(query, 'user', userLat, userLng);
    _addCoordinatePair(query, 'board', boardLat, boardLng);
    _addCoordinatePair(query, 'alight', alightLat, alightLng);
    if (mode != null) {
      query['mode'] = mode;
    }
    final json = await _getJson('/bus/live-route-status', query);
    return V3LiveRouteStatusResponse.fromJson(json);
  }

  /// 실시간 지도 패널용 통합 상태(/navigation/live-status).
  /// 도착·버스위치·보행경로·근처정류장·운행상태를 한 번에 받는다.
  Future<V3LiveStatus> liveStatus({
    required String routeNo,
    required String boardStopId,
    String? routeId,
    String? alightStopId,
    String? sessionId,
    double? userLat,
    double? userLng,
    double? boardLat,
    double? boardLng,
    double? alightLat,
    double? alightLng,
    double? destLat,
    double? destLng,
    String? boardStopName,
    String? alightStopName,
    String? destName,
    String? mode,
  }) async {
    final query = <String, String>{
      'routeNo': routeNo,
      'boardStopId': boardStopId,
    };
    if (routeId != null && routeId.isNotEmpty) query['routeId'] = routeId;
    if (alightStopId != null && alightStopId.isNotEmpty) {
      query['alightStopId'] = alightStopId;
    }
    if (sessionId != null && sessionId.isNotEmpty) {
      query['sessionId'] = sessionId;
    }
    _addCoordinatePair(query, 'user', userLat, userLng);
    _addCoordinatePair(query, 'board', boardLat, boardLng);
    _addCoordinatePair(query, 'alight', alightLat, alightLng);
    _addCoordinatePair(query, 'dest', destLat, destLng);
    if (boardStopName != null && boardStopName.isNotEmpty) {
      query['boardStopName'] = boardStopName;
    }
    if (alightStopName != null && alightStopName.isNotEmpty) {
      query['alightStopName'] = alightStopName;
    }
    if (destName != null && destName.isNotEmpty) query['destName'] = destName;
    if (mode != null) query['mode'] = mode;
    final json = await _getJson('/navigation/live-status', query);
    return V3LiveStatus.fromJson(json);
  }

  Future<V3MockGeofenceResponse> mockGeofence({
    required String sessionId,
    required String event,
  }) async {
    final json = await _postJson('/mock/geofence', <String, Object?>{
      'sessionId': sessionId,
      'event': event,
    });
    return V3MockGeofenceResponse.fromJson(json);
  }

  Future<V3BeaconDecisionResponse> mockBeacons({
    required String sessionId,
    String? targetBusId,
    String? targetRouteNo,
    required List<V3BeaconSignal> beacons,
  }) async {
    final json = await _postJson('/mock/beacons', <String, Object?>{
      'sessionId': sessionId,
      if (targetBusId != null && targetBusId.isNotEmpty)
        'targetBusId': targetBusId,
      if (targetRouteNo != null && targetRouteNo.isNotEmpty)
        'targetRouteNo': targetRouteNo,
      'beacons': beacons.map((beacon) => beacon.toJson()).toList(),
    });
    return V3BeaconDecisionResponse.fromJson(json);
  }

  Future<V3MockGeofenceResponse> mockBusEvent({
    required String sessionId,
    required String event,
  }) async {
    final json = await _postJson('/mock/bus-event', <String, Object?>{
      'sessionId': sessionId,
      'event': event,
    });
    return V3MockGeofenceResponse.fromJson(json);
  }

  Future<V3BeaconDecisionResponse> fetchBeaconDecision({
    required String sessionId,
  }) async {
    final json = await _getJson('/beacon/decision', <String, String>{
      'sessionId': sessionId,
    });
    return V3BeaconDecisionResponse.fromJson(json);
  }

  Future<Map<String, dynamic>> _getJson(
    String path,
    Map<String, String> queryParameters,
  ) async {
    try {
      final response = await _client
          .get(_buildUri(path, queryParameters: queryParameters))
          .timeout(timeout);
      return _decodeResponse(response);
    } on TimeoutException {
      throw const V3ApiException('API 연결 시간이 초과됐어.');
    } on V3ApiException {
      rethrow;
    } catch (_) {
      throw const V3ApiException('API에 연결할 수 없어.');
    }
  }

  Future<Map<String, dynamic>> _postJson(
    String path,
    Map<String, Object?> payload, {
    Duration? customTimeout,
  }) async {
    try {
      final response = await _client
          .post(
            _buildUri(path),
            headers: const <String, String>{'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          )
          .timeout(customTimeout ?? timeout);
      return _decodeResponse(response);
    } on TimeoutException {
      throw const V3ApiException('API 연결 시간이 초과됐어.');
    } on V3ApiException {
      rethrow;
    } catch (_) {
      throw const V3ApiException('API에 연결할 수 없어.');
    }
  }

  Map<String, dynamic> _decodeResponse(http.Response response) {
    final decoded =
        response.body.isEmpty ? <String, dynamic>{} : jsonDecode(response.body);
    final body = decoded is Map ? Map<String, dynamic>.from(decoded) : null;

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw V3ApiException(
        _errorMessage(body) ?? 'API가 ${response.statusCode}를 반환했어.',
        statusCode: response.statusCode,
      );
    }
    if (body == null) {
      throw const V3ApiException('API 응답 형식이 JSON object가 아니야.');
    }
    return body;
  }

  String? _errorMessage(Map<String, dynamic>? body) {
    if (body == null) return null;
    final topLevelError = body['error'];
    if (topLevelError is Map) {
      final code = topLevelError['code']?.toString();
      final message = topLevelError['message']?.toString();
      if (code != null && message != null) return '$code: $message';
      return code ?? message;
    }
    final detail = body['detail'];
    if (detail is Map) {
      final error = detail['error'];
      if (error is Map) {
        final code = error['code']?.toString();
        final message = error['message']?.toString();
        if (code != null && message != null) return '$code: $message';
        return code ?? message;
      }
      return detail['message']?.toString();
    }
    if (detail is String) return detail;
    return body['message']?.toString();
  }

  Uri _buildUri(String path, {Map<String, String>? queryParameters}) {
    final normalizedBaseUrl = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    final uri = Uri.parse('$normalizedBaseUrl$path');
    if (queryParameters == null || queryParameters.isEmpty) {
      return uri;
    }
    return uri.replace(queryParameters: queryParameters);
  }

  void _addCoordinatePair(
    Map<String, String> query,
    String prefix,
    double? latitude,
    double? longitude,
  ) {
    if (latitude == null || longitude == null) return;
    query['${prefix}Lat'] = latitude.toString();
    query['${prefix}Lng'] = longitude.toString();
  }

  http.Client get _client => _httpClient ?? http.Client();
}
