import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:mobi_mobile_auth/mobile_auth.dart';
import '../local_backend/local_backend_probe.dart' show validateLocalBackend;
import '../services/v3_agent_api_client.dart';
import 'frame_pump.dart';

/// Explicit local-test configuration, selected at runtime, never a build define.
/// No admin credential or binding authority is accepted from this file.
class CameraBackendConfig {
  CameraBackendConfig._(this.baseUrl, this.passengerUid, this.producerUid,
      this.cameraId, this._passengerToken, this._producerToken, this.expiresAt);
  final String baseUrl, passengerUid, producerUid, cameraId;
  final String _passengerToken, _producerToken;
  final DateTime expiresAt;
  factory CameraBackendConfig.parse(String source, {required String baseUrl}) {
    validateLocalBackend(baseUrl);
    final value = jsonDecode(source);
    const keys = {
      'scope',
      'baseUrl',
      'passengerUid',
      'producerUid',
      'cameraId',
      'passengerToken',
      'producerToken',
      'expiresAt'
    };
    if (value is! Map<String, dynamic> ||
        value.keys.toSet().difference(keys).isNotEmpty ||
        keys.difference(value.keys.toSet()).isNotEmpty ||
        value['scope'] != 'local-camera-preview-v1' ||
        value['baseUrl'] != baseUrl ||
        ![
          'passengerUid',
          'producerUid',
          'cameraId',
          'passengerToken',
          'producerToken'
        ].every((k) =>
            value[k] is String &&
            (value[k] as String).isNotEmpty &&
            (value[k] as String).length <= 2048)) {
      throw const FormatException('로컬 연결 파일의 형식 또는 주소가 다릅니다.');
    }
    final expiry = DateTime.tryParse(value['expiresAt'].toString());
    if (expiry == null || !expiry.isAfter(DateTime.now().toUtc())) {
      throw const FormatException('로컬 시험 자격이 만료되었습니다. PC에서 다시 준비해 주세요.');
    }
    return CameraBackendConfig._(
        baseUrl,
        value['passengerUid'],
        value['producerUid'],
        value['cameraId'],
        value['passengerToken'],
        value['producerToken'],
        expiry);
  }
}

/// Reuses existing Passenger negotiation and Producer _transport. It cannot
/// register cameras or create bindings. An operator must use the server admin.
class CameraBackendSession {
  CameraBackendSession(this.config, {http.Client? client, this.diagnostic}) {
    _transport =
        _CameraTransport(config.baseUrl, client ?? http.Client(), diagnostic);
    passenger = AuthenticatedApiClient(
        client: _transport,
        tokenLoader: ({bool forceRefresh = false}) async =>
            isCurrent ? config._passengerToken : null,
        requestGuard: () => () => isCurrent);
    producerAuth = AuthenticatedApiClient(
        client: _transport,
        tokenLoader: ({bool forceRefresh = false}) async =>
            isCurrent ? config._producerToken : null,
        requestGuard: () => () => isCurrent);
    api = V3AgentApiClient(
        baseUrl: config.baseUrl,
        visionLeaseEnabled: true,
        authClient: passenger,
        timeout: const Duration(seconds: 3),
        visionLogin: () => VisionLeaseLogin(
            scope: _scope,
            uid: config.passengerUid,
            isCurrent: () => isCurrent));
  }
  final CameraBackendConfig config;
  final void Function(Map<String, Object?>)? diagnostic;
  final Object _scope = Object();
  bool _closed = false;
  bool get isCurrent =>
      !_closed && DateTime.now().toUtc().isBefore(config.expiresAt);
  late final _CameraTransport _transport;
  late final AuthenticatedApiClient passenger, producerAuth;
  late final V3AgentApiClient api;
  String? sessionId;
  Future<void>? _preparing;
  Future<DartVisionProducerClient>? _binding;
  DartVisionProducerClient? producer;

  Future<void> prepare() =>
      _preparing ??= _prepare().whenComplete(() => _preparing = null);
  Future<void> _prepare() async {
    if (!isCurrent) throw const VisionProducerException('로컬 시험 자격이 종료되었습니다.');
    if (sessionId != null) return;
    final response = await _transport
        .get(Uri.parse('${config.baseUrl}/health'))
        .timeout(const Duration(seconds: 3));
    if (response.statusCode != 200 ||
        response.headers['x-mobi-local-probe'] !=
            'fake-auth-memory-vision-v1') {
      throw const VisionProducerException('지정된 PC Vision 시험 서버를 확인해 주세요.');
    }
    _transport.verified = true;
    final session = await api.createSession(wakeWord: 'android-camera-preview');
    if (!isCurrent) throw const VisionProducerException('종료된 로그인 응답을 폐기했습니다.');
    sessionId = session.sessionId;
    diagnostic?.call({'phase': 'session_ready', 'sessionId': sessionId});
  }

  Future<DartVisionProducerClient> confirmBinding() =>
      _binding ??= _confirmBinding().whenComplete(() => _binding = null);
  Future<DartVisionProducerClient> _confirmBinding() async {
    if (!isCurrent || sessionId == null) {
      throw const VisionProducerException('Passenger 세션을 먼저 준비해 주세요.');
    }
    if (producer != null) return producer!;
    final view = await api.fetchVisionObservations(sessionId!);
    if (!isCurrent) throw const VisionProducerException('종료된 로그인 응답을 폐기했습니다.');
    final bindings = (view['bindings'] as List)
        .where((b) =>
            b is Map &&
            b['cameraId'] == config.cameraId &&
            b['producerId'] == config.producerUid &&
            b['sessionId'] == sessionId &&
            b['sourceType'] == 'android_camera')
        .toList();
    if (bindings.length != 1) {
      throw const VisionProducerException(
          'PC에서 이 세션의 관리자 Binding을 승인한 뒤 다시 확인해 주세요.');
    }
    return producer = DartVisionProducerClient(
        baseUrl: config.baseUrl,
        producerUid: config.producerUid,
        authClient: producerAuth,
        binding: Map<String, dynamic>.from(bindings.single),
        diagnostic: diagnostic);
  }

  Future<void> end() async {
    producer?.cancel();
    if (sessionId != null) api.invalidateVisionSession(sessionId!);
    try {
      if (isCurrent) await api.revokeVisionLease();
    } finally {
      close();
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    producer?.close();
    if (sessionId != null) api.invalidateVisionSession(sessionId!);
    _transport.close();
  }
}

/// Same loopback boundary as the existing Android test app. No admin API here.
class _CameraTransport extends http.BaseClient {
  _CameraTransport(this.baseUrl, this.inner, this.record);
  final String baseUrl;
  final http.Client inner;
  final void Function(Map<String, Object?>)? record;
  bool verified = false, closed = false;
  int _sequence = 0;
  final _instance = DateTime.now().toUtc().microsecondsSinceEpoch;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    validateLocalBackend(request.url.origin);
    final path = request.url.path;
    final allowed = (request.method == 'GET' &&
            {'/health', '/guidance/safety-events'}.contains(path)) ||
        (request.method == 'GET' &&
            RegExp(r'^/ai-vision/v2/sessions/[^/]+/observations$')
                .hasMatch(path)) ||
        (request.method == 'POST' &&
            {
              '/guidance/session',
              '/guidance/vision-lease/operations',
              '/guidance/vision-lease',
              '/ai-vision/v2/events'
            }.contains(path)) ||
        (request.method == 'DELETE' && path == '/guidance/vision-lease');
    if (closed ||
        request.url.origin != Uri.parse(baseUrl).origin ||
        request.url.hasFragment ||
        request.url.userInfo.isNotEmpty ||
        !allowed ||
        (!verified && path != '/health')) {
      throw const VisionProducerException('로컬 Camera Preview 전송 범위를 벗어났습니다.');
    }
    request.followRedirects = false;
    final id = 'camera-$_instance-${++_sequence}';
    request.headers['X-Mobi-Local-Attempt'] = id;
    final row = <String, Object?>{
      'attemptId': id,
      'method': request.method,
      'path': path
    };
    try {
      final response = await inner.send(request);
      record?.call({...row, 'status': response.statusCode});
      return response;
    } catch (_) {
      record?.call({...row, 'status': 'transport_error'});
      rethrow;
    }
  }

  @override
  void close() {
    if (!closed) {
      closed = true;
      inner.close();
    }
  }
}
