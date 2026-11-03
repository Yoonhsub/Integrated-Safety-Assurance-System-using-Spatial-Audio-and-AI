import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobi_mobile_auth/mobile_auth.dart';
import 'src/pages/v3_guidance_page.dart';
import 'src/services/local_guidance_runtime.dart';
import 'src/services/session_guidance_audio.dart';
import 'src/services/directional_guidance.dart';
import 'src/services/spatial_verification_engine.dart';
import 'src/services/spatial_verification_output.dart';
import 'src/services/speech_priority_coordinator.dart';
import 'src/services/v3_agent_api_client.dart';
import 'src/services/browser_speech_stub.dart'
    if (dart.library.js_interop) 'src/services/browser_speech_web.dart';

Future<void> main() async {
  const enabled = bool.fromEnvironment('MOBI_LOCAL_GUIDANCE_AUDIO');
  if (!enabled ||
      !kDebugMode ||
      !kIsWeb ||
      !{'127.0.0.1', 'localhost'}.contains(Uri.base.host)) {
    throw StateError('Explicit localhost debug Guidance verification required');
  }
  WidgetsFlutterBinding.ensureInitialized();
  final font = FontLoader('OfflineKorean')
    ..addFont(rootBundle.load('offline-test.ttf'));
  await font.load();
  // Keep every fallback used by the full Widget local as well.
  for (final family in ['Roboto', 'monospace']) {
    await (FontLoader(family)..addFont(rootBundle.load('offline-test.ttf')))
        .load();
  }
  runApp(MaterialApp(
      theme: ThemeData(fontFamily: 'OfflineKorean'), home: const _Runtime()));
}

// Auth fixture exists only in this guarded entry, not in normal main/HomePage.
class _LocalAuth implements AuthSession {
  int epoch = 1;
  final changes = StreamController<AuthAccount?>.broadcast(sync: true);
  AuthAccount? account = const AuthAccount(uid: 'owner');
  bool Function() capture() {
    final e = epoch;
    return () => epoch == e && account != null;
  }

  @override
  AuthAccount? get currentAccount => account;
  @override
  Stream<AuthAccount?> get authStateChanges => changes.stream;
  @override
  Future<void> signOut() async {
    epoch++;
    account = null;
    changes.add(null);
  }

  @override
  Future<AuthAccount> signIn(String email, String password) async {
    epoch++;
    account = const AuthAccount(uid: 'owner');
    changes.add(account);
    return account!;
  }

  @override
  Future<String?> getIdToken({bool forceRefresh = false}) async =>
      account == null ? null : 'offline-only.owner';
  @override
  Future<Object?> getCustomClaim(String name,
          {bool forceRefresh = false}) async =>
      name == 'role' ? 'passenger' : null;
}

/// A single button gesture grants one Cue, not persistent autoplay permission.
/// The receiver still validates the fresh scoped receipt before consuming it.
class _ArmedOutput implements SpatialTestOutput, DirectionalCueOutput {
  final delegate = WebSpatialTestOutput();
  bool armed = false;
  Future<void> arm() async {
    armed = false;
    await delegate.prepareFromGesture();
    armed = true;
  }

  @override
  Future<void> prepareFromGesture() async {
    if (!armed || delegate.snapshot()['contextState'] != 'running') {
      throw StateError('A new explicit Cue gesture is required');
    }
    armed = false;
  }

  @override
  Future<bool> playCue(TestDirection direction) =>
      (delegate as DirectionalCueOutput).playCue(direction);
  @override
  Future<bool> play(String mode, String direction) =>
      delegate.play(mode, direction);
  @override
  Future<void> stop() {
    armed = false;
    return delegate.stop();
  }

  @override
  Future<void> dispose() {
    armed = false;
    return delegate.dispose();
  }

  @override
  Map<String, dynamic> snapshot() => delegate.snapshot();
}

class _Runtime extends StatefulWidget {
  const _Runtime();
  @override
  State<_Runtime> createState() => _RuntimeState();
}

class _RuntimeState extends State<_Runtime> {
  static const backend = 'http://127.0.0.1:8280';
  final auth = _LocalAuth(), output = _ArmedOutput();
  final receipts = <String, LocalDirectionReceipt>{};
  final generations = <String, String>{};
  Completer<void>? _bindingPending;
  final logs = <String>[];
  late final SpatialVerificationEngine engine;
  late final SpeechPriorityCoordinator priority;
  late final V3AgentApiClient api;
  late final LocalGuidanceRuntime runtime;
  final admin = AuthenticatedApiClient(
      tokenLoader: ({bool forceRefresh = false}) async => 'offline-only.admin');
  int page = 0;
  bool active = true, busy = false;
  void record(String text) {
    if (mounted) {
      setState(() {
        logs.add(text);
        if (logs.length > 20) logs.removeAt(0);
      });
    }
  }

  @override
  void initState() {
    super.initState();
    engine = SpatialVerificationEngine(output, createBrowserSpeechEngine()!,
        onGuidanceTrace: (id, p) => record('$id $p'));
    priority = SpeechPriorityCoordinator(engine);
    api = V3AgentApiClient(
        baseUrl: backend,
        authClient: AuthenticatedApiClient(
            tokenLoader: auth.getIdToken,
            onUnauthorized: auth.signOut,
            requestGuard: auth.capture));
    runtime = LocalGuidanceRuntime(
        client: api,
        auth: auth,
        captureGuard: auth.capture,
        priority: priority,
        audio: SessionGuidanceAudio.localVerification(
            priority: priority,
            engine: engine,
            authEpoch: () => auth.epoch,
            receipt: receipts.remove,
            waitForLocalBinding: () =>
                _bindingPending?.future ?? Future<void>.value(),
            onScope: (sid, gen) {
              generations
                ..clear()
                ..[sid] = gen;
            },
            diagnostic: record,
            trace: (event) => record('AUDIO_TRACE ${jsonEncode(event)}')),
        controls: (sid, hold, stop) => Column(children: [
              const Text('LOCAL SYNTHETIC · 실제 V3 Guidance 수신 경로 · TTS 비공간화'),
              const Text(
                  '음성 스위치를 먼저 켜세요. 같은 문구는 반복하지 않습니다. 방향별 검증 전 세션 초기화 후 스위치를 다시 켜세요. 이벤트 입장 기한은 3초이며, 시작한 문장은 세션이 유효하면 완료합니다.'),
              Wrap(spacing: 8, children: [
                TextButton(
                    onPressed: busy ? null : () => emit(sid, null),
                    child: const Text('정보성 TTS 이벤트')),
                for (final d in TestDirection.values)
                  TextButton(
                      onPressed: busy ? null : () => emit(sid, d),
                      child: Text('${d.name.toUpperCase()} 세션 이벤트')),
                TextButton(
                    onPressed:
                        busy ? null : () => emit(sid, null, noEvent: true),
                    child: const Text('REAL no_event 재전달')),
                TextButton(
                    onPressed: () => guarded(hold),
                    child: const Text('Live Hold 선점')),
                TextButton(
                    onPressed: () => guarded(stop), child: const Text('STOP')),
              ])
            ]));
  }

  Future<void> guarded(Future<void> Function() action) async {
    try {
      await action();
      record('CONTROL_CONFIRMED');
    } catch (e) {
      record('CONTROL_ERROR ${e.runtimeType}');
    }
  }

  Future<void> emit(String sid, TestDirection? direction,
      {bool noEvent = false}) async {
    if (busy || auth.currentAccount == null) return;
    setState(() => busy = true);
    final binding = Completer<void>();
    _bindingPending = binding;
    final valid = auth.capture();
    try {
      // Arm synchronously from the actual button, before HTTP/polling awaits.
      if (direction != null) await output.arm();
      final generation = generations[sid];
      if (generation == null) {
        throw StateError('Verified receiver baseline required');
      }
      if (!valid() || !mounted || !active) return;
      final fixture = await admin.get(Uri.parse(
          '$backend/__test/${noEvent ? 'real-no-event' : 'fixture'}'));
      if (fixture.statusCode != 200) throw StateError('Fixture unavailable');
      final response = await admin.post(
          Uri.parse('$backend/ai-vision/events').replace(
              queryParameters: {'sessionId': sid, 'generation': generation}),
          headers: {'Content-Type': 'application/json'},
          body: fixture.body);
      if (!valid() || !mounted || !active) return;
      final body = jsonDecode(response.body) as Map;
      if (direction != null && response.statusCode == 201) {
        final id = (body['safetyEvent'] as Map)['eventId'] as String;
        receipts.clear();
        receipts[id] = LocalDirectionReceipt(
            sessionId: sid,
            ownerUid: 'owner',
            generation: generation,
            authEpoch: auth.epoch,
            eventId: id,
            createdAt: DateTime.now(),
            direction: direction);
      }
      record(
          '${noEvent ? 'REAL_MODEL_NO_EVENT_REPLAY' : 'SYNTHETIC_EVENT_GUIDANCE'} HTTP ${response.statusCode} stored=${body['stored']}');
    } catch (e) {
      record('EMIT_ERROR ${e.runtimeType}');
      if (direction != null) await output.stop();
    } finally {
      if (!binding.isCompleted) binding.complete();
      if (identical(_bindingPending, binding)) _bindingPending = null;
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> leave() async {
    setState(() => active = false);
    receipts.clear();
    await auth.signOut();
    try {
      await engine.dispose();
      record('AUDIO_CLOSED');
    } catch (e) {
      record('CLEANUP_ERROR ${e.runtimeType}');
    }
    priority.dispose();
  }

  @override
  void dispose() {
    unawaited(auth.signOut());
    receipts.clear();
    unawaited(engine.dispose().catchError((Object e) {
      debugPrint('Guidance cleanup ${e.runtimeType}');
    }));
    priority.dispose();
    unawaited(auth.changes.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
          body: Column(children: [
        SafeArea(
            child: Wrap(children: [
          TextButton(
              onPressed: active
                  ? () => setState(() {
                        page++;
                        receipts.clear();
                      })
                  : null,
              child: const Text('새 Guidance 세션')),
          TextButton(
              onPressed: active ? leave : null, child: const Text('페이지 종료')),
        ])),
        if (active)
          Expanded(
              child: V3GuidancePage(
                  key: ValueKey(page),
                  agentName: '자비스',
                  dataMode: 'live',
                  onReturnToModeSelection: leave,
                  localRuntime: runtime))
        else
          const Text('페이지 종료 · 오디오 폐기'),
        SizedBox(
            height: 100,
            child: SingleChildScrollView(child: Text(logs.join('\n')))),
      ]));
}
