import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:mobi_mobile_auth/mobile_auth.dart';
import '../services/v3_agent_api_client.dart';
import '../services/session_safety_receiver.dart';
import '../services/speech_priority_coordinator.dart';

void validateLocalBackend(String baseUrl) {
  final uri = Uri.tryParse(baseUrl);
  if (!kDebugMode ||
      uri == null ||
      uri.scheme != 'http' ||
      uri.host != '127.0.0.1' ||
      uri.port != 8000 ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      (uri.path.isNotEmpty && uri.path != '/')) {
    throw StateError('Explicit debug http://127.0.0.1:8000 required');
  }
}

/// Network guard and sanitized request/response correlation, never auth logging.
class LocalBackendTransport extends http.BaseClient {
  LocalBackendTransport(this.inner, this.record);
  final http.Client inner;
  final void Function(Map<String, Object?>) record;
  bool closed = false;
  bool _verifiedHost = false;
  int _sequence = 0;
  final _origin = DateTime.now().toUtc().microsecondsSinceEpoch;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    validateLocalBackend(request.url.origin);
    const reads = {'/health', '/guidance/state', '/guidance/safety-events'};
    const writes = {'/guidance/session', '/guidance/reset', '/guidance/event'};
    if (closed ||
        (request.url.path != '/health' && !_verifiedHost) ||
        request.url.userInfo.isNotEmpty ||
        request.url.hasFragment ||
        !request.url.queryParameters.keys
            .every({'sessionId', 'generation', 'after'}.contains) ||
        !((request.method == 'GET' && reads.contains(request.url.path)) ||
            (request.method == 'POST' && writes.contains(request.url.path)))) {
      throw StateError('Outside local Backend verification scope');
    }
    request.followRedirects = false;
    final id = 'android-debug-$_origin-${++_sequence}';
    request.headers['X-Mobi-Local-Attempt'] = id;
    final entry = <String, Object?>{
      'attemptId': id,
      'method': request.method,
      'path': request.url.path,
      'utc': DateTime.now().toUtc().toIso8601String()
    };
    record({...entry, 'phase': 'send'});
    try {
      final response = await inner.send(request);
      if (request.url.path == '/health') {
        _verifiedHost = response.statusCode == 200 &&
            response.headers['x-mobi-local-probe'] == 'fake-auth-memory-v1';
        if (response.statusCode == 200 && !_verifiedHost) {
          throw StateError('Dedicated Fake-auth local host marker missing');
        }
      }
      record({...entry, 'phase': 'response', 'status': response.statusCode});
      return response;
    } catch (error) {
      record({
        ...entry,
        'phase': 'transport_error',
        'type': error.runtimeType.toString()
      });
      rethrow;
    }
  }

  @override
  void close() {
    if (closed) return;
    closed = true;
    inner.close();
  }
}

// Disabled sink for the existing receiver, never a native audio engine.
class _NoAudio implements SpeechEngine {
  @override
  Future<void> prepare({required bool requireKoreanVoice}) async =>
      throw StateError('Audio is forbidden in the HTTP probe');
  @override
  Future<void> speak(String text) async =>
      throw StateError('Audio is forbidden');
  @override
  Future<void> stop() async {}
}

class LocalBackendProbe extends ChangeNotifier {
  LocalBackendProbe({required String baseUrl, http.Client? transport}) {
    validateLocalBackend(baseUrl);
    raw = LocalBackendTransport(transport ?? http.Client(), _record);
    api = _api(baseUrl, 'owner', invalidateOn401: true);
    other = _api(baseUrl, 'other');
    admin = _api(baseUrl, 'admin');
  }
  late final LocalBackendTransport raw;
  late final V3AgentApiClient api, other, admin;
  final priority = SpeechPriorityCoordinator(_NoAudio());
  final records = <Map<String, Object?>>[];
  SessionSafetyReceiver? receiver;
  SafetyPollingTransport? _polling;
  int _epoch = 0, _scope = 0, _operation = 0;
  bool _closed = false, _signedIn = true, busy = false;
  String status = '로컬 Fake 인증 · Firebase 미사용', sessionId = '', generation = '';

  V3AgentApiClient _api(String baseUrl, String identity,
          {bool invalidateOn401 = false}) =>
      V3AgentApiClient(
          baseUrl: baseUrl,
          timeout: const Duration(seconds: 3),
          httpClient: raw,
          authClient: AuthenticatedApiClient(
              client: raw,
              tokenLoader: ({bool forceRefresh = false}) async =>
                  _signedIn ? 'offline-only.$identity' : null,
              requestGuard: () {
                final epoch = _epoch;
                return () => !_closed && _signedIn && epoch == _epoch;
              },
              onUnauthorized: () async {
                if (invalidateOn401) logout();
              }));

  void _record(Map<String, Object?> entry) {
    if (_closed) return;
    records.add(entry);
    if (records.length > 160) records.removeAt(0);
    debugPrint('LOCAL_BACKEND_TRACE ${jsonEncode(entry)}');
    notifyListeners();
  }

  void _haltReceiver() {
    _scope++;
    final old = receiver;
    receiver = null;
    old?.dispose();
    _polling?.close();
    _polling = null;
  }

  void logout() {
    if (_closed) return;
    _epoch++;
    _operation++;
    _signedIn = false;
    _haltReceiver();
    sessionId = '';
    generation = '';
    status = '로그아웃 · 이전 epoch/요청 결과 폐기';
    notifyListeners();
  }

  void relogin() {
    logout();
    if (_closed) return;
    _signedIn = true;
    status = '새 Fake 로그인 세대';
    notifyListeners();
  }

  Future<void> _bind(String sid) async {
    _haltReceiver();
    final scope = _scope, epoch = _epoch;
    final ready = Completer<void>();
    final polling = api.openSafetyPolling();
    _polling = polling;
    final item = SessionSafetyReceiver(
        sessionId: sid,
        ownerUid: 'owner',
        priority: priority,
        isCurrent: () =>
            !_closed && _signedIn && epoch == _epoch && scope == _scope,
        cancelFetch: polling.close,
        fetch: (s, a, g) async {
          final data = await polling.fetch(s, a, g);
          if (!_closed && scope == _scope && epoch == _epoch) {
            generation = data['generation'] as String;
          }
          return data;
        });
    receiver =
        item; // enabled remains false: no messages or sound are admitted.
    item.addListener(() {
      if (scope != _scope || _closed) return;
      if (item.status == '안전 이벤트 연결됨' && !ready.isCompleted) ready.complete();
      status = item.status;
      notifyListeners();
    });
    await ready.future.timeout(const Duration(seconds: 6));
  }

  /// Explicit user action. No camera, AI ingestion, Safety Event or audio API.
  Future<void> verify() async {
    if (_closed || busy) return;
    if (!_signedIn) relogin();
    busy = true;
    final operation = ++_operation, epoch = _epoch;
    bool current() =>
        !_closed && _signedIn && epoch == _epoch && operation == _operation;
    Future<T> step<T>(String label, Future<T> work) async {
      final value = await work;
      if (!current()) throw const StaleAuthRequestException();
      _record({'phase': 'check', 'check': label});
      return value;
    }

    _haltReceiver();
    status = '실제 HTTP 검사 중';
    notifyListeners();
    try {
      final health = await step('health', api.fetchHealth());
      if (!health.isAvailable) throw StateError('Health unavailable');
      final unauth = await step(
          'unauthenticated',
          raw
              .post(Uri.parse('${api.baseUrl}/guidance/session'),
                  headers: {'Content-Type': 'application/json'}, body: '{}')
              .timeout(const Duration(seconds: 3)));
      if (unauth.statusCode != 401) throw StateError('Expected401');
      final state =
          await step('session_create', api.createSession(wakeWord: '로컬 연결 시험'));
      sessionId = state.sessionId;
      await step('session_state', api.fetchState(sessionId: sessionId));
      await step('receiver_baseline', _bind(sessionId));
      try {
        await step('foreign_owner', other.fetchState(sessionId: sessionId));
        throw StateError('Foreign owner accepted');
      } on V3ApiException catch (e) {
        if (e.statusCode != 403) rethrow;
      }
      if (!current()) throw const StaleAuthRequestException();
      final old = generation;
      _haltReceiver();
      await step('reset', api.resetSession(sessionId: sessionId));
      await step('new_receiver_baseline', _bind(sessionId));
      if (generation == old) throw StateError('Generation did not change');
      status = '로컬 HTTP PASS · polling 활성 · Android Runtime은 양쪽 trace로 별도 확인';
      _record({
        'phase': 'result',
        'result': 'LOCAL_HTTP_CHECKS_PASS',
        'sessionId': sessionId,
        'generation': generation
      });
    } catch (error) {
      if (current()) {
        _haltReceiver();
        status = 'BLOCKED: ${error.runtimeType} · 자동 재전송 없음';
        _record({'phase': 'failed', 'type': error.runtimeType.toString()});
      }
    } finally {
      if (!_closed) {
        busy = false;
        notifyListeners();
      }
    }
  }

  Future<void> endSession() async {
    if (_closed || busy || sessionId.isEmpty) return;
    busy = true;
    final epoch = _epoch, sid = sessionId;
    _haltReceiver();
    bool current() => !_closed && _signedIn && epoch == _epoch;
    try {
      // Existing admin-only state API; explicitly labelled fixture administrator.
      for (final event in [
        'ROUTE_RECOMMENDED',
        'WAITING_FOR_BUS',
        'BOARDING_CONFIRMATION',
        'BOARDED'
      ]) {
        if (!current()) throw const StaleAuthRequestException();
        await admin.applyGuidanceEvent(sessionId: sid, event: event);
      }
      if (!current()) throw const StaleAuthRequestException();
      final probe = api.openSafetyPolling();
      try {
        await probe.fetch(sid, null, null);
        throw StateError('Ended session accepted');
      } on SafetyPollingException catch (e) {
        if (!e.terminal) rethrow;
      } finally {
        probe.close();
      }
      if (current()) {
        status = '종료된 세션 polling 거부 PASS';
        sessionId = '';
        generation = '';
      }
    } catch (error) {
      if (current()) status = '종료 확인 BLOCKED: ${error.runtimeType}';
    } finally {
      if (!_closed) {
        busy = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    if (_closed) return;
    _closed = true;
    _epoch++;
    _operation++;
    _haltReceiver();
    raw.close();
    priority.dispose();
    super.dispose();
  }
}
