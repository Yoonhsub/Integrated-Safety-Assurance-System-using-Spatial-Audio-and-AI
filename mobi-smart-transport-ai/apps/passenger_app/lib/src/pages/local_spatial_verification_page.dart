import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../services/spatial_verification_engine.dart';
import '../services/directional_guidance.dart';
import '../services/session_guidance_audio.dart';
import '../services/speech_priority_coordinator.dart';
import '../services/audio_haptic_cue_service.dart';
import '../services/audio_shutdown.dart';
import '../models/v3_guidance_models.dart';

/// Local explicit debug page. No Backend, Firebase, sensors or automatic sound.
class LocalSpatialVerificationPage extends StatefulWidget {
  const LocalSpatialVerificationPage(
      {super.key,
      this.enabled = false,
      this.nativeStereoOnly = false,
      this.stopOnBackground = false,
      this.mockBusControls = false,
      required this.output,
      required this.tts,
      this.cuesFactory,
      this.onLogout});
  final bool enabled, nativeStereoOnly, stopOnBackground, mockBusControls;
  final Future<void> Function()? onLogout;
  final SpatialTestOutput output;
  final SpeechEngine tts;
  final AudioHapticCueService Function(SpeechPriorityCoordinator)? cuesFactory;
  @override
  State<LocalSpatialVerificationPage> createState() => _SpatialState();
}

class _SpatialState extends State<LocalSpatialVerificationPage>
    with WidgetsBindingObserver {
  final _clock = Stopwatch()..start();
  late final SpatialVerificationEngine _engine;
  late final SpeechPriorityCoordinator _priority;
  late final AudioHapticCueService _cues;
  final _owner = Object();
  Timer? _timer;
  int _epoch = 1, _request = 0, _generation = 1;
  bool _current = true,
      _failed = false,
      _stopping = false,
      _hold = false,
      _disposed = false;
  Map<String, dynamic> _probe = {};
  final _log = <String>[];
  String _heard = 'AUDIBLE_INTEGRATION_NOT_VERIFIED';
  int _guidanceNumber = 0;
  DirectionalGuidance? _lastGuidance;
  bool get _allowed => kDebugMode && widget.enabled;
  bool get _mockBusAllowed =>
      _allowed && widget.nativeStereoOnly && widget.mockBusControls;
  bool _valid(int epoch, int request) =>
      mounted &&
      !_disposed &&
      _current &&
      !_failed &&
      epoch == _epoch &&
      request == _request;
  void _record(String value) {
    if (!mounted || _disposed) return;
    setState(() {
      _log.add(value);
      if (_log.length > 32) _log.removeAt(0);
    });
  }

  @override
  void initState() {
    super.initState();
    if (widget.stopOnBackground) WidgetsBinding.instance.addObserver(this);
    _engine = SpatialVerificationEngine(widget.output, widget.tts,
        onGuidanceTrace: (id, phase) => _record('$id $phase'));
    _priority = SpeechPriorityCoordinator(_engine);
    _cues = widget.cuesFactory?.call(_priority) ??
        AudioHapticCueService(speechPriority: _priority);
    if (_allowed) {
      _timer = Timer.periodic(const Duration(milliseconds: 200), (_) {
        final probe = widget.output.snapshot();
        if (mounted && jsonEncode(probe) != jsonEncode(_probe)) {
          setState(() => _probe = probe);
        }
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (widget.stopOnBackground &&
        state != AppLifecycleState.resumed &&
        !_disposed &&
        !_stopping) {
      unawaited(_stop('APP_BACKGROUND', end: true));
    }
  }

  Future<void> _play(String mode, String direction) async {
    if (!_allowed || !_current || _failed || _stopping || _hold) return;
    final epoch = _epoch, request = ++_request;
    try {
      // Called only from a button. Resume occurs within the user activation.
      await widget.output.prepareFromGesture();
      if (!_valid(epoch, request)) return;
      final complete = await _priority.speakObservation(
          _owner, '@spatial:$mode:$direction', () => _valid(epoch, request));
      if (_valid(epoch, request)) {
        _record('$mode $direction ${complete ? 'COMPLETED' : 'CANCELLED'}');
      }
    } on SpeechCancelled {
      if (_valid(epoch, request)) _record('CANCELLED');
    } catch (_) {
      if (_valid(epoch, request)) {
        _failed = true;
        _record('AUDIO_BLOCKED · reload required');
      }
    }
  }

  Future<void> _newGuidance(TestDirection? direction) async {
    final guidance = DirectionalGuidance(
        guidanceId: 'local-guidance-${++_guidanceNumber}',
        sessionGeneration: _generation.toString(),
        authEpoch: _epoch,
        priority: GuidancePriority.observation,
        text: direction == null
            ? '방향 정보 없이 일반 음성만 재생하는 로컬 테스트입니다.'
            : '방향 Cue 다음에 일반 음성이 나오는 로컬 테스트입니다.',
        provenance: DirectionalGuidance.syntheticProvenance,
        testDirection: direction,
        directionEvidence: DirectionEvidence.explicitLocalFixture);
    await _submitGuidance(guidance);
  }

  Future<void> _submitGuidance(DirectionalGuidance guidance) async {
    if (!_allowed || !_current || _failed || _stopping || _hold) return;
    if (guidance.authEpoch != _epoch ||
        guidance.sessionGeneration != _generation.toString()) {
      _record('OLD_GUIDANCE_SCOPE_REJECTED');
      return;
    }
    final epoch = _epoch;
    var request = _request;
    bool current() => _valid(epoch, request) && !_priority.priorityActive;
    final admission = widget.nativeStereoOnly
        ? ObservationAdmission(
            deadlineMicros: _clock.elapsedMicroseconds + 3000000,
            nowMicros: () => _clock.elapsedMicroseconds,
            eventId: guidance.guidanceId,
            sessionGeneration: guidance.sessionGeneration,
            receivedAt: DateTime.now().toUtc().toIso8601String())
        : null;
    final command = _engine.registerGuidance(guidance, current,
        admit: admission?.admit, phase: admission?.phase);
    if (command == null) {
      _record('DUPLICATE_GUIDANCE_IGNORED ${guidance.guidanceId}');
      return;
    }
    request = ++_request;
    _lastGuidance = guidance;
    _record(
        'SYNTHETIC_DIRECTIONAL_GUIDANCE ${guidance.guidanceId} epoch=$epoch generation=$_generation');
    try {
      // Explicit gesture unlock only for a reviewed direction; never for TTS-only.
      if (guidance.hasReviewedDirection) {
        await widget.output.prepareFromGesture();
      }
      if (!current()) return;
      final complete = await _priority.speakObservation(
          _owner, command, current,
          admit: admission?.admit,
          onDeadline: () => admission?.cancel('PLAYBACK_WATCHDOG'));
      admission?.finish(complete);
      if (current()) {
        _record(
            '${guidance.guidanceId} ${complete ? 'GUIDANCE_COMPLETED' : 'GUIDANCE_CANCELLED'}');
      }
    } on SpeechCancelled {
      if (_valid(epoch, request)) _record('GUIDANCE_CANCELLED');
    } catch (_) {
      if (_valid(epoch, request)) {
        _failed = true;
        _record('GUIDANCE_BLOCKED · reload required');
      }
    } finally {
      _engine.retireGuidance(command);
    }
  }

  Future<void> _tts() async {
    if (!_allowed || !_current || _failed || _stopping || _hold) return;
    final epoch = _epoch, request = ++_request;
    try {
      await _priority.speakObservation(
          _owner, '테스트 음성 출력입니다.', () => _valid(epoch, request));
      if (_valid(epoch, request)) _record('TTS_COMPLETED · NOT_SPATIALIZED');
    } on SpeechCancelled {
      if (_valid(epoch, request)) _record('TTS_CANCELLED');
    } catch (_) {
      if (_valid(epoch, request)) {
        _failed = true;
        _record('TTS_BLOCKED');
      }
    }
  }

  Future<void> _liveHold() async {
    if (!_allowed || !_current || _failed || _stopping || _hold) return;
    setState(() => _hold = true);
    final epoch = _epoch;
    _request++;
    _record('LIVE_HOLD_REQUEST');
    try {
      await _cues.speakLocal('검증용 Live Hold 안내입니다. 방향 테스트 소리를 중단했습니다.');
      if (mounted && _current && epoch == _epoch) {
        _record('LIVE_HOLD_COMPLETED');
      }
    } on SpeechCancelled {
      if (mounted && epoch == _epoch) _record('LIVE_HOLD_CANCELLED');
    } catch (_) {
      if (mounted && epoch == _epoch) {
        _failed = true;
        _record('HOLD_BLOCKED');
      }
    } finally {
      if (mounted && epoch == _epoch) setState(() => _hold = false);
    }
  }

  // Explicit local test inputs only. No bus identity or AI detection assertion.
  Future<void> _mockBusSpeech() async {
    if (!_mockBusAllowed || !_current || _failed || _stopping || _hold) return;
    final epoch = _epoch, request = ++_request;
    _record('SYNTHETIC_BUS_TTS_REQUEST');
    try {
      await _priority.speakObservation(
          _owner,
          '모의 버스 안내입니다. 선택한 버스의 접근을 안내하는 시험입니다. '
          '실제 차량 확인이나 탑승 허가는 아닙니다. 정류장 안에서 다음 안내를 기다려 주세요.',
          () => _valid(epoch, request));
      if (_valid(epoch, request)) _record('SYNTHETIC_BUS_TTS_COMPLETED');
    } on SpeechCancelled {
      if (mounted && epoch == _epoch) _record('SYNTHETIC_BUS_TTS_CANCELLED');
    } catch (_) {
      if (_valid(epoch, request)) {
        _failed = true;
        _record('SYNTHETIC_BUS_TTS_BLOCKED');
      }
    }
  }

  Future<void> _mockObstacleDanger() async {
    if (!_mockBusAllowed || !_current || _failed || _stopping || _hold) return;
    setState(() => _hold = true);
    _request++;
    _record('SYNTHETIC_OBSTACLE_DANGER_REQUEST');
    try {
      await _cues.playCue(const V3Cue(
          type: 'DANGER',
          ttsMode: 'SAFETY_LOCAL',
          shouldVibrate: true,
          shouldBeep: true,
          message: '모의 장애물 경고입니다. 멈춰 주세요.'));
      if (mounted && !_disposed) _record('SYNTHETIC_DANGER_DISPATCHED');
    } catch (_) {
      if (mounted && !_disposed) _record('SYNTHETIC_DANGER_OUTPUT_FAILED');
    }
    // Keep the warning lease until the existing STOP/session cleanup is used.
  }

  Future<void> _stop(String reason,
      {bool end = false, bool reset = false}) async {
    if (!_allowed || _stopping) return;
    setState(() {
      _stopping = true;
      _current = false;
      _epoch++;
      _request++;
      _hold = false;
    });
    _record('OLD_AUDIO_INVALIDATED $reason');
    try {
      await Future.wait([_priority.stopObservation(_owner), _cues.stopCue()]);
      // Also confirms silence if no coordinator run existed.
      await _engine.stop().timeout(const Duration(seconds: 3));
      if (!mounted || _disposed) return;
      if (reset) _generation++;
      _current = !end && !_failed;
      _record('STOP_CONFIRMED $reason generation=$_generation');
    } catch (_) {
      if (mounted && !_disposed) {
        _failed = true;
        _record('STOP_UNCONFIRMED · reload required');
      }
    } finally {
      if (mounted && !_disposed) setState(() => _stopping = false);
    }
  }

  Future<void> _logout() async {
    await _stop('LOGOUT', end: true);
    if (_disposed || !mounted || widget.onLogout == null) return;
    try {
      await widget.onLogout!();
    } catch (_) {
      if (mounted && !_disposed) {
        _failed = true;
        _record('AUTH_LOGOUT_FAILED · 음성은 중단된 상태입니다');
      }
    }
  }

  Future<void> _exitPage() async {
    if (!_allowed || _disposed || _stopping) return;
    // Navigation transitions keep the old Widget mounted. Retire audio now,
    // before any Cue completion can start its following utterance.
    await _stop('PAGE_EXIT', end: true);
    if (!mounted || _disposed) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('검증 페이지 종료 · 잔여 소리 확인'))));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _disposed = true;
    _current = false;
    _epoch++;
    _request++;
    _timer?.cancel();
    unawaited(observeAudioCleanup(() async {
      try {
        await _cues.dispose();
      } finally {
        try {
          await _engine.dispose();
        } finally {
          _priority.dispose();
        }
      }
    },
        report: (message) => debugPrint(message),
        channel: 'Local audio cleanup'));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_allowed) {
      return const Scaffold(body: Text('SPATIAL_VERIFICATION_BLOCKED'));
    }
    final ready = _current && !_failed && !_stopping && !_hold;
    return Scaffold(
        appBar: AppBar(
            title: Text(widget.nativeStereoOnly
                ? 'Android Stereo Cue + TTS · 검증'
                : 'LOCAL Spatial Audio · 검증 전용')),
        body: SingleChildScrollView(
            child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                          '로컬 생성 테스트 음원. 실제 버스·거리·출입문·Head Tracking 정보가 아닙니다.'),
                      const Text(
                          '헤드폰 좌우 채널을 확인하세요. 자동 재생 없음. TTS는 공간화되지 않습니다.'),
                      Text(widget.nativeStereoOnly
                          ? 'Stereo 채널: LEFT=L, CENTER=L/R 동일, RIGHT=R. 3D 정면·거리 검증 아님.'
                          : '좌표: listener=(0,0,0), 정면=-Z, 오른쪽=+X, 위=+Y; LEFT=(-1,0,-1), CENTER=(0,0,-1), RIGHT=(1,0,-1). 테스트 임의 단위.'),
                      Text(
                          'epoch=$_epoch · generation=$_generation · current=$_current'),
                      Text(
                          'Engine: ${_probe['phase']} · context=${_probe['contextState']} · active=${_probe['active']} · run=${_probe['runId']}'),
                      if (_failed)
                        const Text('AUDIO_BLOCKED · 새 음원 금지, reload required'),
                      for (final mode in (widget.nativeStereoOnly
                          ? ['STEREO']
                          : ['STEREO', 'HRTF']))
                        Wrap(spacing: 8, children: [
                          for (final direction in ['CENTER', 'LEFT', 'RIGHT'])
                            ElevatedButton(
                                onPressed:
                                    ready ? () => _play(mode, direction) : null,
                                child: Text('$mode $direction'))
                        ]),
                      Text(widget.nativeStereoOnly
                          ? 'Android Stereo PCM Cue → 한국어 로컬 TTS · HRTF/실기기 청취 미검증'
                          : '단일 합성 안내: 짧은 HRTF Cue → 기존 일반 TTS (음성 공간화 아님)'),
                      if (_mockBusAllowed) ...[
                        const Text('수동 모의 입력 · 실제 버스/장애물 감지가 아닙니다. '
                            '버스 음성 도중 장애물 경고를 눌러 선점을 확인하고 STOP으로 종료하세요.'),
                        Wrap(spacing: 8, children: [
                          ElevatedButton(
                              onPressed: ready ? _mockBusSpeech : null,
                              child: const Text('모의 버스 안내')),
                          ElevatedButton(
                              onPressed: ready ? _mockObstacleDanger : null,
                              child: const Text('모의 장애물 경고')),
                        ]),
                      ],
                      if (widget.nativeStereoOnly)
                        ExpansionTile(
                            title: const Text('Native 출력 경로·TTS 상태'),
                            children: [Text(jsonEncode(_probe))]),
                      Wrap(spacing: 8, children: [
                        for (final direction in TestDirection.values)
                          ElevatedButton(
                              onPressed:
                                  ready ? () => _newGuidance(direction) : null,
                              child: Text(
                                  '${direction.name.toUpperCase()} Cue → TTS')),
                        ElevatedButton(
                            onPressed: ready ? () => _newGuidance(null) : null,
                            child: const Text('방향 없는 TTS 안내')),
                        OutlinedButton(
                            onPressed: ready && _lastGuidance != null
                                ? () => _submitGuidance(_lastGuidance!)
                                : null,
                            child: const Text('직전 guidanceId 재전송'))
                      ]),
                      Wrap(spacing: 8, children: [
                        ElevatedButton(
                            onPressed: ready ? _tts : null,
                            child: const Text('TTS 원본 출력')),
                        ElevatedButton(
                            onPressed: ready ? _liveHold : null,
                            child: const Text('Live Hold 선점')),
                        OutlinedButton(
                            onPressed: !_stopping ? () => _stop('STOP') : null,
                            child: const Text('STOP')),
                        OutlinedButton(
                            onPressed: !_stopping
                                ? () => _stop('SESSION_END', end: true)
                                : null,
                            child: const Text('세션 종료')),
                        OutlinedButton(
                            onPressed: !_stopping ? _logout : null,
                            child: const Text('로그아웃')),
                        OutlinedButton(
                            onPressed: !_stopping
                                ? () => _stop('RESET', reset: true)
                                : null,
                            child: const Text('Reset / 새 generation')),
                        OutlinedButton(
                            onPressed: !_current && !_failed && !_stopping
                                ? () {
                                    setState(() {
                                      _epoch++;
                                      _current = true;
                                    });
                                  }
                                : null,
                            child: const Text('새 세션')),
                        OutlinedButton(
                            onPressed: !_stopping ? _exitPage : null,
                            child: const Text('페이지 종료'))
                      ]),
                      Text('실제 청취: $_heard'),
                      Wrap(children: [
                        for (final answer in [
                          'LEFT',
                          'CENTER',
                          'RIGHT',
                          '구분 안 됨'
                        ])
                          TextButton(
                              onPressed: () => setState(
                                  () => _heard = 'USER_REPORTED $answer'),
                              child: Text('들린 방향: $answer'))
                      ]),
                      ..._log.map(Text.new)
                    ]))));
  }
}
