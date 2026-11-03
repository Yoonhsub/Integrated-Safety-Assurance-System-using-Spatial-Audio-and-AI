import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:mobi_mobile_auth/mobile_auth.dart';

import '../models/v3_guidance_models.dart';
import 'converse_live.dart';
import 'session_safety_receiver.dart';

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
  V3AgentApiClient({
    required this.baseUrl,
    this.timeout = const Duration(seconds: 60),
    http.Client? httpClient,
    bool visionLeaseEnabled = FirebaseAuthSession.localDemo,
    VisionLeaseLogin? Function()? visionLogin,
    AuthenticatedApiClient? authClient,
  })  : _visionLeaseEnabled = visionLeaseEnabled,
        _leaseRequiredAtStartup = visionLeaseEnabled,
        _visionLogin = visionLogin ?? VisionLeaseLogin.firebase,
        _httpClient = httpClient,
        _authClient = authClient ??
            AuthenticatedApiClient(
              onUnauthorized: FirebaseAuthSession.instance.signOut,
            );

  static const Duration _converseTimeout = Duration(seconds: 45);

  final String baseUrl;
  final Duration timeout;
  final http.Client? _httpClient;
  final AuthenticatedApiClient _authClient;
  // Normal Guidance remains unleased until the user enables own-phone preview.
  // Existing local clients can retain mandatory startup lease negotiation.
  final bool _leaseRequiredAtStartup;
  bool _visionLeaseEnabled;
  bool get _normalUsesLease =>
      _leaseRequiredAtStartup || _lastVisionState?.receipt != null;
  bool visionSessionReady(String sessionId) =>
      _lastVisionState?.sessions[sessionId]?.ready == true &&
      _lastVisionState!.login.isCurrent();
  bool get visionLeaseEnabled => _visionLeaseEnabled;
  final VisionLeaseLogin? Function() _visionLogin;
  static final _logins = Expando<Map<String, _VisionLoginState>>();
  _VisionLoginState? _lastVisionState;
  static final Map<String, _SafetyFlight> _visionFlights = {};

  _VisionLoginState _visionState() {
    if (!visionLeaseEnabled) throw const VisionLeaseException(terminal: true);
    final login = _visionLogin();
    if (login == null || !login.isCurrent()) {
      throw const VisionLeaseException(terminal: true);
    }
    final origin = _buildUri('/').toString();
    final entries = _logins[login.scope] ??= {};
    final state = entries.putIfAbsent(origin, () => _VisionLoginState(login));
    state.check();
    _lastVisionState = state;
    return state;
  }

  /// One operation per immutable login scope, including retries after a lost
  /// response. Never replace the operation in response to an auth/fencing error.
  Future<void> prepareVisionLease() {
    final state = _visionState();
    if (state.receipt != null) {
      state.checkReceipt();
      return Future.value();
    }
    return state.negotiating ??= _negotiateLease(state).whenComplete(() {
      state.negotiating = null;
    });
  }

  Future<void> _negotiateLease(_VisionLoginState state) async {
    if (state.ticket == null) {
      final ticket = await _visionWire(
          state, 'POST', '/guidance/vision-lease/operations',
          body: {'operationId': state.operation});
      if (ticket['operationId'] != state.operation ||
          ticket['version'] is! int ||
          ticket['version'] < 1 ||
          ticket['startTicket'] is! String ||
          !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(ticket['startTicket']) ||
          DateTime.tryParse(ticket['expiresAt']?.toString() ?? '') == null) {
        state.terminal = true;
        throw const VisionLeaseException(terminal: true);
      }
      state.ticket = {
        for (final k in ['operationId', 'startTicket', 'version']) k: ticket[k]
      };
    }
    final receipt = await _visionWire(state, 'POST', '/guidance/vision-lease',
        body: state.ticket);
    final expires = DateTime.tryParse(receipt['expiresAt']?.toString() ?? '');
    if (receipt['ownerUid'] != state.login.uid ||
        receipt['status'] != 'active' ||
        receipt['version'] != state.ticket!['version'] ||
        receipt['leaseId'] is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(receipt['leaseId']) ||
        expires == null ||
        !expires.isAfter(DateTime.now())) {
      state.terminal = true;
      throw const VisionLeaseException(terminal: true);
    }
    state.check();
    state.receipt = receipt;
    state.expires = expires;
    state.remaining = expires.difference(DateTime.now());
    state.age = Stopwatch()..start();
  }

  Map<String, String> _leaseHeaders() {
    if (!visionLeaseEnabled) return const {};
    final state = _visionState()..checkReceipt();
    return {'X-Mobi-Vision-Lease': state.receipt!['leaseId'] as String};
  }

  Future<Map<String, dynamic>> _visionWire(
      _VisionLoginState state, String method, String path,
      {Map<String, Object?>? body,
      Map<String, String>? query,
      bool leased = false}) async {
    state.check();
    final key = Uri.parse(baseUrl).origin;
    if (_visionFlights.containsKey(key)) {
      throw const VisionLeaseException(blocked: true);
    }
    final headers = <String, String>{
      'Content-Type': 'application/json',
      if (leased) ..._leaseHeaders()
    };
    final uri = _buildUri(path, queryParameters: query);
    final flight = _SafetyFlight();
    _visionFlights[key] = flight;
    state.flight = flight;
    state.flightSession = query?['sessionId'] ??
        (path.contains('/observations')
            ? Uri.decodeComponent(path.split('/')[4])
            : null);
    final raw = switch (method) {
      'POST' => _authClient.post(uri,
          headers: headers,
          body: jsonEncode(body),
          abortTrigger: flight.abort.future),
      'DELETE' => _authClient.delete(uri,
          headers: headers, abortTrigger: flight.abort.future),
      _ => _authClient.get(uri,
          headers: headers, abortTrigger: flight.abort.future),
    };
    // Retain the shared slot until the ORIGINAL auth/transport/body future ends,
    // even when timeout/cancellation cannot terminate an underlying transport.
    void finished() {
      if (identical(_visionFlights[key], flight)) _visionFlights.remove(key);
      if (identical(state.flight, flight)) {
        state.flight = null;
        state.flightSession = null;
      }
    }

    unawaited(raw.then<void>((_) => finished(),
        onError: (Object _, StackTrace __) => finished()));
    try {
      final response =
          await raw.timeout(const Duration(seconds: 2), onTimeout: () {
        flight.cancel();
        throw const VisionLeaseException(blocked: true);
      });
      state.check();
      if (leased) state.checkReceipt();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final terminal =
            {400, 401, 403, 404, 409, 410, 422}.contains(response.statusCode);
        state.terminal = terminal;
        throw VisionLeaseException(terminal: terminal);
      }
      final decoded = response.body.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) throw const FormatException();
      return decoded;
    } on AuthenticatedApiException catch (error) {
      state.terminal = {401, 403, 499}.contains(error.statusCode);
      throw VisionLeaseException(terminal: state.terminal);
    } on VisionLeaseException {
      rethrow;
    } catch (_) {
      throw const VisionLeaseException();
    }
  }

  Future<void> _bindVisionSession(String sessionId) async {
    final state = _visionState()..checkReceipt();
    final scope = state.sessions.putIfAbsent(sessionId, _VisionSession.new);
    final revision = scope.revision;
    final baseline = await _visionWire(state, 'GET', '/guidance/safety-events',
        query: {'sessionId': sessionId}, leased: true);
    if (scope.revision != revision ||
        baseline['sessionId'] != sessionId ||
        baseline['ownerUid'] != state.login.uid ||
        baseline['generation'] is! String ||
        (baseline['generation'] as String).isEmpty) {
      throw const VisionLeaseException(terminal: true);
    }
    if (scope.generation != baseline['generation']) {
      scope.authority = null;
      scope.serverRevision = -1;
    }
    scope.generation = baseline['generation'] as String;
    scope.ready = true;
  }

  /// Immediately closes local admission. Cleanup is bound to the old bearer
  /// generation and old lease header; a late DELETE cannot revoke a newer slot.
  Future<void> revokeVisionLease() async {
    if (!visionLeaseEnabled) return;
    final state = _lastVisionState ?? _visionState();
    state.check();
    for (final scope in state.sessions.values) {
      scope.ready = false;
      scope.revision++;
    }
    state.flight?.cancel();
    try {
      if (state.receipt != null) {
        await _visionWire(state, 'DELETE', '/guidance/vision-lease',
            leased: true);
      }
    } finally {
      state.terminal = true;
      state.receipt = null;
    }
  }

  void invalidateVisionSession(String sessionId) {
    if (!visionLeaseEnabled) return;
    final state = _lastVisionState;
    final scope = state?.sessions[sessionId];
    if (scope != null) {
      scope.ready = false;
      scope.revision++;
      if (state!.flightSession == sessionId) state.flight?.cancel();
    }
  }

  /// User-initiated own-phone preview. Normal route planning remains usable
  /// without negotiating a Vision lease at app startup.
  Future<Map<String, dynamic>> startPassengerCamera(String sessionId) async {
    _visionLeaseEnabled = true;
    await prepareVisionLease();
    final state = _visionState()..checkReceipt();
    final binding = await _visionWire(state, 'POST',
        '/ai-vision/v2/sessions/${Uri.encodeComponent(sessionId)}/phone-camera',
        leased: true);
    if (binding['sessionId'] != sessionId ||
        binding['producerId'] != state.login.uid ||
        binding['sourceType'] != 'android_camera' ||
        !_serverUuid(binding['bindingId']) ||
        !_serverUuid(binding['cameraEpoch']) ||
        !_serverInt(binding['nextFrameIndex'])) {
      throw const VisionLeaseException(terminal: true);
    }
    await _bindVisionSession(sessionId);
    return Map<String, dynamic>.unmodifiable(binding);
  }

  Future<void> sendPassengerCamera(Map<String, dynamic> binding,
      Map<String, Object?> result, int frameIndex) async {
    final state = _visionState()..checkReceipt();
    final sessionId = binding['sessionId'] as String;
    if (state.sessions[sessionId]?.ready != true) {
      throw const VisionLeaseException(terminal: true);
    }
    final receipt = await _visionWire(state, 'POST',
        '/ai-vision/v2/sessions/${Uri.encodeComponent(sessionId)}/phone-camera/events',
        leased: true,
        body: {
          for (final key in [
            'bindingId',
            'cameraId',
            'producerId',
            'sessionId',
            'cameraEpoch',
            'sourceType'
          ])
            key: binding[key],
          'envelopeVersion': '2.0.0',
          'visionEventId': result['frameId'],
          'capturedAt': result['capturedAt'],
          'captureClock': 'host_read',
          'frameIndex': frameIndex,
          'detectionResult': result,
        });
    if (receipt['visionEventId'] != result['frameId'] ||
        receipt['bindingId'] != binding['bindingId'] ||
        receipt['accepted'] != true ||
        receipt['guidanceEligible'] != false) {
      throw const VisionLeaseException(terminal: true);
    }
  }

  Future<void> stopPassengerCamera(Map<String, dynamic> binding) async {
    await _visionWire(_visionState(), 'DELETE',
        '/ai-vision/v2/sessions/${Uri.encodeComponent(binding['sessionId'] as String)}/phone-camera/${binding['bindingId']}',
        leased: true);
  }

  Future<V3HealthStatus> fetchHealth() async {
    try {
      final response = await _client.get(_buildUri('/health')).timeout(timeout);
      final ok = response.statusCode >= 200 && response.statusCode < 300;
      return V3HealthStatus(
        isAvailable: ok,
        message: ok ? '백엔드 연결 성공' : '백엔드가 ${response.statusCode}를 반환했습니다.',
      );
    } on TimeoutException {
      return const V3HealthStatus(
        isAvailable: false,
        message: '백엔드 연결 시간이 초과됐습니다.',
      );
    } catch (_) {
      return const V3HealthStatus(
        isAvailable: false,
        message: '백엔드에 연결할 수 없습니다.',
      );
    }
  }

  Future<V3GuidanceState> createSession({required String wakeWord}) async {
    if (_normalUsesLease) await prepareVisionLease();
    final json = await _postJson('/guidance/session', <String, Object?>{
      'wakeWord': wakeWord,
    });
    final result = V3GuidanceState.fromJson(json);
    if (_normalUsesLease) await _bindVisionSession(result.sessionId);
    return result;
  }

  Future<V3GuidanceState> fetchState({required String sessionId}) async {
    final json = await _getJson('/guidance/state', <String, String>{
      'sessionId': sessionId,
    });
    return V3GuidanceState.fromJson(json);
  }

  Future<Map<String, dynamic>> fetchVisionObservations(String sessionId) async {
    final state = _visionState()..checkReceipt();
    final scope = state.sessions[sessionId];
    if (scope == null) {
      throw const VisionLeaseException(terminal: true);
    }
    if (!scope.ready) throw const VisionLeaseException(blocked: true);
    final revision = scope.revision;
    final sequence = ++scope.sequence;
    bool current() =>
        scope.ready &&
        scope.revision == revision &&
        scope.sequence == sequence &&
        state.login.isCurrent();
    final path =
        '/ai-vision/v2/sessions/${Uri.encodeComponent(sessionId)}/observations';
    final result = await _visionWire(state, 'GET', path, leased: true);
    if (!current()) throw const VisionLeaseException(blocked: true);
    // An authoritative SECOND snapshot, from the same binding/session lock
    // boundary, not a local remembered revision or a safety-generation proxy.
    final proof = await _visionWire(state, 'GET', path,
        query: {'proofOnly': 'true'}, leased: true);
    if (!current()) throw const VisionLeaseException(blocked: true);
    Map<String, String> dataBindings, proofBindings;
    try {
      dataBindings = _bindingSnapshot(result, state, scope, sessionId);
      proofBindings = _bindingSnapshot(proof, state, scope, sessionId);
      if ((proof['observations'] as List).isNotEmpty) {
        throw const VisionLeaseException(terminal: true);
      }
    } on VisionLeaseException {
      scope.ready = false;
      rethrow;
    }
    final authority = proof['authority'] as String;
    final serverRevision = proof['viewRevision'] as int;
    if (scope.authority != null && scope.authority != authority) {
      scope.ready = false;
      throw const VisionLeaseException(terminal: true);
    }
    if (serverRevision < scope.serverRevision) {
      throw const VisionLeaseException(blocked: true);
    }
    scope.authority = authority;
    scope.serverRevision = serverRevision;
    if (result['authority'] != authority ||
        result['viewRevision'] != serverRevision ||
        jsonEncode(dataBindings) != jsonEncode(proofBindings)) {
      // A genuine remote lifecycle change discards this response without
      // permanently disabling the next valid rebind/empty observation poll.
      throw const VisionLeaseException(blocked: true);
    }
    for (final value in result['observations'] as List) {
      if (value is! Map ||
          value['sessionId'] != sessionId ||
          value['generation'] != scope.generation ||
          value['guidanceEligible'] != false ||
          !dataBindings.containsKey(value['cameraId']) ||
          _bindingSignature(value) != dataBindings[value['cameraId']]) {
        throw const VisionLeaseException(blocked: true);
      }
    }
    if (!current()) throw const VisionLeaseException(blocked: true);
    return result;
  }

  static bool _serverInt(Object? value, {int minimum = 0}) =>
      value is int && value >= minimum && value <= 9007199254740991;
  static bool _serverUuid(Object? value) =>
      value is String &&
      RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')
          .hasMatch(value);
  static String _bindingSignature(Map value) {
    if (!_serverUuid(value['bindingId']) ||
        !_serverUuid(value['cameraEpoch']) ||
        !_serverInt(value['bindingRevision'], minimum: 1) ||
        value['producerId'] is! String ||
        value['cameraId'] is! String ||
        !{'live', 'replay', 'android_camera'}.contains(value['sourceType'])) {
      throw const VisionLeaseException(terminal: true);
    }
    return jsonEncode([
      value['bindingId'],
      value['bindingRevision'],
      value['cameraEpoch'],
      value['producerId'],
      value['cameraId'],
      value['sourceType']
    ]);
  }

  static Map<String, String> _bindingSnapshot(Map packet,
      _VisionLoginState state, _VisionSession scope, String sessionId) {
    if (packet['sessionId'] != sessionId ||
        packet['ownerUid'] != state.login.uid ||
        packet['generation'] != scope.generation ||
        packet['leaseVersion'] != state.receipt!['version'] ||
        !_serverInt(packet['leaseVersion'], minimum: 1) ||
        !_serverUuid(packet['authority']) ||
        !_serverInt(packet['viewRevision']) ||
        packet['bindings'] is! List ||
        packet['observations'] is! List) {
      throw const VisionLeaseException(terminal: true);
    }
    final bindings = <String, String>{};
    final ids = <String>{};
    final values = List.of(packet['bindings'] as List);
    for (final value in values) {
      if (value is! Map ||
          value['sessionId'] != sessionId ||
          !_serverInt(value['bindingRevision'], minimum: 1) ||
          value['bindingRevision'] > packet['viewRevision'] ||
          value['cameraId'] is! String ||
          bindings.containsKey(value['cameraId']) ||
          !ids.add(value['bindingId']?.toString() ?? '')) {
        throw const VisionLeaseException(terminal: true);
      }
      bindings[value['cameraId'] as String] = _bindingSignature(value);
    }
    return Map.fromEntries(
        bindings.entries.toList()..sort((a, b) => a.key.compareTo(b.key)));
  }

  // Shared across clients/receivers: a non-cancelling transport cannot be
  // bypassed by rebuilding a panel, changing users or creating another client.
  static final Map<String, _SafetyFlight> _safetyFlights = {};
  late final SafetyPollingTransport _legacySafety = openSafetyPolling();
  SafetyPollingTransport openSafetyPolling() => _SafetyTransport(this);

  Future<Map<String, dynamic>> fetchSafetyEvents(
          String sessionId, int? after, String? generation) =>
      _legacySafety.fetch(sessionId, after, generation);

  Future<Map<String, dynamic>> _fetchSafetyEvents(_SafetyTransport owner,
      String sessionId, int? after, String? generation) async {
    if (owner.closed) throw const SafetyPollingException(terminal: true);
    Map<String, String> leaseHeaders;
    try {
      leaseHeaders = _normalUsesLease ? _leaseHeaders() : const {};
    } on VisionLeaseException {
      throw const SafetyPollingException(terminal: true);
    }
    final key = Uri.parse(baseUrl).origin;
    if (_safetyFlights.containsKey(key)) {
      throw const SafetyPollingException(blocked: true);
    }
    final flight = _SafetyFlight();
    owner.flight = flight;
    _safetyFlights[key] = flight;
    final raw = _authClient.get(
        _buildUri('/guidance/safety-events', queryParameters: {
          'sessionId': sessionId,
          if (after != null) 'after': '$after',
          if (generation != null) 'generation': generation,
        }),
        headers: leaseHeaders,
        abortTrigger: flight.abort.future);
    void finished() {
      if (identical(_safetyFlights[key], flight)) _safetyFlights.remove(key);
      if (identical(owner.flight, flight)) owner.flight = null;
    }

    // Release only after ORIGINAL HTTP/auth/body processing terminates.
    unawaited(raw.then<void>((_) {
      finished();
    }, onError: (Object _, StackTrace __) {
      finished();
    }));
    try {
      final response =
          await raw.timeout(const Duration(seconds: 2), onTimeout: () {
        flight.cancel();
        throw const SafetyPollingException(blocked: true);
      });
      if (owner.closed) throw const SafetyPollingException(terminal: true);
      return _decodeResponse(response);
    } on AuthenticatedApiException catch (error) {
      throw SafetyPollingException(
          terminal: {401, 403, 499}.contains(error.statusCode));
    } on http.RequestAbortedException {
      throw SafetyPollingException(
          terminal: owner.closed, blocked: !owner.closed);
    }
  }

  Future<V3GuidanceState> resetSession({required String sessionId}) async {
    invalidateVisionSession(sessionId);
    final json = await _postJson('/guidance/reset', <String, Object?>{
      'sessionId': sessionId,
      'event': 'RESET',
      'payload': <String, Object?>{},
    });
    if (visionLeaseEnabled) await _bindVisionSession(sessionId);
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
    String? nluProvider,
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
          if (nluProvider != null) 'nluProvider': nluProvider,
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
    String? nluProvider,
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
        if (nluProvider != null) 'nluProvider': nluProvider,
      },
    );
  }

  Future<Uint8List> synthesizeSpeech({
    required String text,
    String? provider,
    String? model,
  }) async {
    try {
      final response = await _authClient
          .post(
            _buildUri('/agent/tts'),
            headers: const <String, String>{'Content-Type': 'application/json'},
            body: jsonEncode(<String, Object?>{
              'text': text,
              if (provider != null) 'provider': provider,
              if (model != null) 'model': model,
            }),
          )
          .timeout(const Duration(seconds: 20));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw V3ApiException(
          'Gemini TTS를 사용할 수 없습니다.',
          statusCode: response.statusCode,
        );
      }
      return response.bodyBytes;
    } on TimeoutException {
      throw const V3ApiException('Gemini TTS 연결 시간이 초과됐습니다.');
    } on AuthenticatedApiException catch (error) {
      throw V3ApiException(error.userMessage, statusCode: error.statusCode);
    } on V3ApiException {
      rethrow;
    } catch (_) {
      throw const V3ApiException('Gemini TTS에 연결할 수 없습니다.');
    }
  }

  Future<V3RouteRecommendResponse> routeRecommend({
    required String destination,
    double? originLat,
    double? originLng,
    String? mode,
    String? nluProvider,
  }) async {
    final query = <String, String>{'destination': destination};
    if (originLat != null && originLng != null) {
      query['originLat'] = originLat.toString();
      query['originLng'] = originLng.toString();
    }
    if (mode != null) {
      query['mode'] = mode;
    }
    if (nluProvider != null) {
      query['nluProvider'] = nluProvider;
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
    final query = <String, String>{'q': q};
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
      String path, Map<String, String> queryParameters,
      {Duration? customTimeout}) async {
    final login = _normalUsesLease ? _visionState() : null;
    try {
      final response = await _authClient
          .get(_buildUri(path, queryParameters: queryParameters),
              headers: _normalUsesLease ? _leaseHeaders() : const {})
          .timeout(customTimeout ?? timeout);
      login?.check();
      return _decodeResponse(response);
    } on TimeoutException {
      throw const V3ApiException('API 연결 시간이 초과됐습니다.');
    } on AuthenticatedApiException catch (error) {
      throw V3ApiException(error.userMessage, statusCode: error.statusCode);
    } on V3ApiException {
      rethrow;
    } catch (_) {
      throw const V3ApiException('API에 연결할 수 없습니다.');
    }
  }

  Future<Map<String, dynamic>> _postJson(
    String path,
    Map<String, Object?> payload, {
    Duration? customTimeout,
  }) async {
    final login = _normalUsesLease ? _visionState() : null;
    try {
      final response = await _authClient
          .post(
            _buildUri(path),
            headers: <String, String>{
              'Content-Type': 'application/json',
              if (_normalUsesLease) ..._leaseHeaders()
            },
            body: jsonEncode(payload),
          )
          .timeout(customTimeout ?? timeout);
      login?.check();
      return _decodeResponse(response);
    } on TimeoutException {
      throw const V3ApiException('API 연결 시간이 초과됐습니다.');
    } on AuthenticatedApiException catch (error) {
      throw V3ApiException(error.userMessage, statusCode: error.statusCode);
    } on V3ApiException {
      rethrow;
    } catch (_) {
      throw const V3ApiException('API에 연결할 수 없습니다.');
    }
  }

  Map<String, dynamic> _decodeResponse(http.Response response) {
    final decoded =
        response.body.isEmpty ? <String, dynamic>{} : jsonDecode(response.body);
    final body = decoded is Map ? Map<String, dynamic>.from(decoded) : null;

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw V3ApiException(
        _errorMessage(body) ?? 'API가 ${response.statusCode}를 반환했습니다.',
        statusCode: response.statusCode,
      );
    }
    if (body == null) {
      throw const V3ApiException('API 응답 형식이 JSON object가 아닙니다.');
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

class _SafetyFlight {
  final abort = Completer<void>();
  void cancel() {
    if (!abort.isCompleted) abort.complete();
  }
}

class _SafetyTransport implements SafetyPollingTransport {
  _SafetyTransport(this.api);
  final V3AgentApiClient api;
  bool closed = false;
  _SafetyFlight? flight;
  @override
  Future<Map<String, dynamic>> fetch(
          String sessionId, int? after, String? generation) =>
      api._fetchSafetyEvents(this, sessionId, after, generation);
  @override
  void close() {
    closed = true;
    flight?.cancel();
  }
}

/// Local lifecycle metadata, never authentication or a server-selected version.
class VisionLeaseLogin {
  VisionLeaseLogin(
      {required this.scope, required this.uid, required this.isCurrent});
  final Object scope;
  final String uid;
  final bool Function() isCurrent;
  static VisionLeaseLogin? firebase() {
    final auth = FirebaseAuthSession.instance;
    final uid = auth.currentAccount?.uid;
    if (uid == null) return null;
    return VisionLeaseLogin(
        scope: auth.loginScope,
        uid: uid,
        isCurrent: auth.captureRequestGuard());
  }
}

class VisionLeaseException implements Exception {
  const VisionLeaseException({this.terminal = false, this.blocked = false});
  final bool terminal, blocked;
  @override
  String toString() => terminal
      ? 'Vision 로그인 또는 세션이 유효하지 않습니다.'
      : blocked
          ? '이전 Vision 요청 종료를 기다리고 있습니다.'
          : 'Vision 연결을 확인해 주세요.';
}

class _VisionSession {
  int sequence = 0, serverRevision = -1;
  String? authority;
  int revision = 0;
  bool ready = false;
  String? generation;
}

class _VisionLoginState {
  _VisionLoginState(this.login) : operation = _operation();
  final VisionLeaseLogin login;
  final String operation;
  Map<String, Object?>? ticket;
  Map<String, dynamic>? receipt;
  Future<void>? negotiating;
  _SafetyFlight? flight;
  String? flightSession;
  bool terminal = false;
  DateTime? expires;
  Duration remaining = Duration.zero;
  Stopwatch age = Stopwatch();
  final sessions = <String, _VisionSession>{};
  void check() {
    if (terminal || !login.isCurrent()) {
      throw const VisionLeaseException(terminal: true);
    }
  }

  void checkReceipt() {
    check();
    if (receipt == null ||
        expires == null ||
        !expires!.isAfter(DateTime.now()) ||
        age.elapsed >= remaining) {
      throw const VisionLeaseException(terminal: true);
    }
  }

  static String _operation() {
    final random = Random.secure();
    final b = List.generate(16, (_) => random.nextInt(256));
    b[6] = (b[6] & 15) | 64;
    b[8] = (b[8] & 63) | 128;
    final h = b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
  }
}
