import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../services/audio_haptic_cue_service.dart';
import '../services/speech_priority_coordinator.dart';
import '../services/v3_agent_api_client.dart';
import '../services/tts_diagnostics_stub.dart'
    if (dart.library.js_interop) '../services/tts_diagnostics_web.dart';
import '../widgets/session_safety_panel.dart';

/// Explicit debug-only local verification UI. Never imported by normal main.dart.
/// Auth/store are injected; the SpeechEngine is the existing production adapter.
class LocalTtsVerificationPage extends StatefulWidget {
  const LocalTtsVerificationPage(
      {super.key,
      this.enabled = false,
      required this.api,
      required this.priority,
      required this.cues,
      required this.emitSynthetic,
      required this.fetchHold,
      this.probe});
  final bool enabled;
  final V3AgentApiClient api;
  final SpeechPriorityCoordinator priority;
  final AudioHapticCueService cues;
  final Future<Map<String, dynamic>> Function(String, String) emitSynthetic;
  final Future<String> Function(String) fetchHold;
  final Map<String, dynamic> Function()? probe;
  @override
  State<LocalTtsVerificationPage> createState() =>
      _LocalTtsVerificationPageState();
}

class _LocalTtsVerificationPageState extends State<LocalTtsVerificationPage> {
  final _manualOwner = Object();
  final _auth = StreamController<Object?>.broadcast(sync: true);
  SessionSafetyLifecycle? _lifecycle;
  Timer? _timer;
  String? _sid, _generation;
  int _epoch = 0;
  bool _current = true,
      _armed = false,
      _manualBusy = false,
      _holdBusy = false,
      _failed = false,
      _sessionBusy = false,
      _endBusy = false;
  Map<String, dynamic> _diagnostics = {};
  final _log = <String>[];
  String _result = 'AUDIBLE_OUTPUT_NOT_VERIFIED';
  bool get _allowed => kDebugMode && widget.enabled;
  bool _valid(int epoch) => mounted && _current && epoch == _epoch;
  void _record(String value) {
    if (!mounted) return;
    setState(() {
      _log.add('${DateTime.now().toUtc().toIso8601String()} $value');
      if (_log.length > 40) _log.removeAt(0);
    });
  }

  @override
  void initState() {
    super.initState();
    if (!_allowed) return;
    _timer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      final next = (widget.probe ?? readTtsDiagnostics)();
      if (mounted && jsonEncode(next) != jsonEncode(_diagnostics)) {
        setState(() => _diagnostics = next);
      }
    });
    _newSession();
  }

  Future<void> _newSession() async {
    if (!_allowed || _sessionBusy || _endBusy || _current && _sid != null) {
      return;
    }
    setState(() => _sessionBusy = true);
    final epoch = ++_epoch;
    _current = true;
    try {
      final session = await widget.api.createSession(wakeWord: '자비스');
      if (!_valid(epoch)) return;
      final baseline =
          await widget.api.fetchSafetyEvents(session.sessionId, null, null);
      if (!_valid(epoch)) return;
      if (baseline['sessionId'] != session.sessionId ||
          baseline['ownerUid'] != 'owner' ||
          baseline['generation'] is! String) {
        throw StateError('Scope mismatch');
      }
      setState(() {
        _sid = session.sessionId;
        _generation = baseline['generation'] as String;
        _lifecycle = SessionSafetyLifecycle();
        _armed = false;
      });
      _record('LOCAL_SESSION_READY epoch=$epoch; no automatic speech');
    } catch (_) {
      if (_valid(epoch)) _record('LOCAL_SESSION_FAILED');
    } finally {
      if (mounted) setState(() => _sessionBusy = false);
    }
  }

  Future<void> _testSpeech() async {
    if (!_allowed ||
        !_current ||
        _failed ||
        _manualBusy ||
        _holdBusy ||
        _diagnostics['localKoreanAvailable'] != true) {
      return;
    }
    setState(() {
      _armed = true;
      _manualBusy = true;
    });
    final epoch = _epoch;
    _record('MANUAL_SPEAK_REQUEST');
    try {
      final completed = await widget.priority
          .speakObservation(_manualOwner, '테스트 음성 출력입니다.', () => _valid(epoch));
      if (_valid(epoch)) {
        _record(completed ? 'MANUAL_COMPLETION_CONFIRMED' : 'MANUAL_CANCELLED');
      }
    } on SpeechCancelled {
      if (_valid(epoch)) _record('MANUAL_CANCELLED');
    } catch (_) {
      if (_valid(epoch)) {
        _failed = true;
        _record('TTS_FAILED · reload required');
      }
    } finally {
      if (_valid(epoch)) setState(() => _manualBusy = false);
    }
  }

  Future<void> _emit() async {
    if (!_armed ||
        !_current ||
        _failed ||
        _sid == null ||
        _generation == null) {
      return;
    }
    final epoch = _epoch;
    try {
      final result = await widget.emitSynthetic(_sid!, _generation!);
      if (!_valid(epoch)) return;
      if (result['httpStatus'] != 201 ||
          result['stored'] != true ||
          result['source'] != 'ai_vision_mock') {
        throw StateError('Invalid synthetic receipt');
      }
      _record('SYNTHETIC_EVENT_HTTP_201 · model=MOCK; not real door detection');
    } catch (_) {
      if (_valid(epoch)) _record('SYNTHETIC_EVENT_FAILED');
    }
  }

  Future<void> _hold() async {
    if (!_armed || !_current || _failed || _holdBusy || _sid == null) return;
    setState(() => _holdBusy = true);
    final epoch = _epoch;
    _record('LIVE_HOLD_REQUEST');
    var playbackAttempted = false;
    try {
      final message = await widget.fetchHold(_sid!);
      if (!_valid(epoch)) return;
      playbackAttempted = true;
      await widget.cues.speakLocal('검증용 Live Hold 안내입니다. $message');
      if (_valid(epoch)) _record('LIVE_HOLD_COMPLETED');
    } on SpeechCancelled {
      if (_valid(epoch)) _record('LIVE_HOLD_CANCELLED');
    } catch (_) {
      if (_valid(epoch)) {
        if (playbackAttempted) {
          _failed = true;
          _record('LIVE_HOLD_FAILED · reload required');
        } else {
          _record('LIVE_HOLD_BACKEND_FAILED · no speech requested');
        }
      }
    } finally {
      if (_valid(epoch)) setState(() => _holdBusy = false);
    }
  }

  Future<void> _end({bool relogin = false}) async {
    if (_endBusy || !_allowed) return;
    setState(() {
      _endBusy = true;
      _current = false;
      _epoch++;
      _armed = false;
      _manualBusy = false;
      _holdBusy = false;
    });
    _auth.add(relogin
        ? 'owner'
        : null); // Same UID still invalidates the pinned epoch.
    _lifecycle?.dispose();
    _lifecycle = null;
    _record(relogin ? 'SAME_UID_EPOCH_INVALIDATED' : 'SESSION_ENDED_OR_LOGOUT');
    try {
      await widget.priority.stopObservation(_manualOwner);
      await widget.cues.stopCue();
      _record('STOP_ACKNOWLEDGED · verify native state and listen separately');
    } catch (_) {
      _failed = true;
      _record('STOP_UNCONFIRMED · new audio blocked; reload required');
    } finally {
      if (mounted) setState(() => _endBusy = false);
    }
    if (relogin && !_failed && mounted) await _newSession();
  }

  @override
  void dispose() {
    _current = false;
    _epoch++;
    _timer?.cancel();
    _auth.add(null);
    _auth.close();
    _lifecycle?.dispose();
    unawaited(widget.priority
        .stopObservation(_manualOwner)
        .catchError((Object _) {}));
    unawaited(widget.cues.dispose().catchError((Object _) {}));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_allowed) {
      return const Scaffold(body: Text('LOCAL_TTS_VERIFICATION_BLOCKED'));
    }
    final counts = _diagnostics['counts'];
    return Scaffold(
        appBar: AppBar(title: const Text('LOCAL TTS · 합성 검증 전용')),
        body: SingleChildScrollView(
            child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                          'Fake 인증·메모리 Backend / 실제 Web Speech 엔진. 실제 버스 안전 안내가 아닙니다.'),
                      const Text(
                          '자동 재생 없음. 1번 버튼을 직접 누르세요. 이후 세션 음성 스위치를 켜고 합성 안내를 요청하세요.'),
                      Text(
                          '엔진: ${_diagnostics['phase']} · speaking=${_diagnostics['nativeSpeaking']} · pending=${_diagnostics['nativePending']}'),
                      Text(
                          '한국어 로컬 음성=${_diagnostics['localKoreanAvailable']} · 선택 local=${_diagnostics['selectedVoiceLocal']} / ${_diagnostics['selectedVoiceLang']}'),
                      Text('Engine callbacks: $counts'),
                      Text('청취 판정: $_result'),
                      if (_failed) const Text('AUDIO_BLOCKED · 앱을 새로 열어 주세요'),
                      Wrap(spacing: 8, children: [
                        ElevatedButton(
                            onPressed: !_failed &&
                                    _current &&
                                    !_manualBusy &&
                                    !_holdBusy &&
                                    _diagnostics['localKoreanAvailable'] == true
                                ? _testSpeech
                                : null,
                            child: const Text('1. 테스트 음성 출력')),
                        ElevatedButton(
                            onPressed:
                                _armed && _current && !_failed && !_manualBusy
                                    ? _emit
                                    : null,
                            child: const Text('2. 합성 안내 수신')),
                        ElevatedButton(
                            onPressed:
                                _armed && _current && !_failed && !_holdBusy
                                    ? _hold
                                    : null,
                            child: const Text('3. Live Hold 선점')),
                        OutlinedButton(
                            onPressed:
                                !_endBusy && _current ? () => _end() : null,
                            child: const Text('4. 세션 종료·음성 중지')),
                        OutlinedButton(
                            onPressed: !_endBusy && _current
                                ? () => _end(relogin: true)
                                : null,
                            child: const Text('동일 UID 재로그인')),
                        OutlinedButton(
                            onPressed: !_current &&
                                    !_sessionBusy &&
                                    !_endBusy &&
                                    !_failed
                                ? _newSession
                                : null,
                            child: const Text('새 세션')),
                      ]),
                      Wrap(spacing: 8, children: [
                        TextButton(
                            onPressed: () =>
                                setState(() => _result = 'USER_REPORTED_HEARD'),
                            child: const Text('직접 들었음')),
                        TextButton(
                            onPressed: () => setState(
                                () => _result = 'USER_REPORTED_STOPPED'),
                            child: const Text('중단·잔여 음성 없음 확인')),
                        TextButton(
                            onPressed: () => setState(
                                () => _result = 'USER_REPORTED_NO_SOUND'),
                            child: const Text('소리 없음')),
                      ]),
                      if (_armed && _sid != null && _lifecycle != null)
                        SessionSafetyHost(
                            key: ValueKey(_sid),
                            lifecycle: _lifecycle!,
                            sessionId: _sid!,
                            ownerUid: 'owner',
                            captureGuard: () {
                              final epoch = _epoch;
                              return () => _valid(epoch);
                            },
                            fetch: widget.api.fetchSafetyEvents,
                            openTransport: widget.api.openSafetyPolling,
                            authChanges: _auth.stream,
                            priority: widget.priority,
                            allowSynthetic: true),
                      const Divider(),
                      ..._log.map((line) => Text(line)),
                    ]))));
  }
}
