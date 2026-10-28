import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../services/spatial_verification_engine.dart';
import '../services/speech_priority_coordinator.dart';
import '../services/audio_haptic_cue_service.dart';

/// Local explicit debug page. No Backend, Firebase, sensors or automatic sound.
class LocalSpatialVerificationPage extends StatefulWidget {
  const LocalSpatialVerificationPage(
      {super.key,
      this.enabled = false,
      required this.output,
      required this.tts,
      this.cuesFactory});
  final bool enabled;
  final SpatialTestOutput output;
  final SpeechEngine tts;
  final AudioHapticCueService Function(SpeechPriorityCoordinator)? cuesFactory;
  @override
  State<LocalSpatialVerificationPage> createState() => _SpatialState();
}

class _SpatialState extends State<LocalSpatialVerificationPage> {
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
  String _heard = 'AUDIBLE_DIRECTION_NOT_VERIFIED';
  bool get _allowed => kDebugMode && widget.enabled;
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
    _engine = SpatialVerificationEngine(widget.output, widget.tts);
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

  @override
  void dispose() {
    _disposed = true;
    _current = false;
    _epoch++;
    _request++;
    _timer?.cancel();
    unawaited(() async {
      try {
        await _cues.dispose();
      } finally {
        try {
          await _engine.dispose();
        } finally {
          _priority.dispose();
        }
      }
    }()
        .catchError((Object _) {}));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_allowed) {
      return const Scaffold(body: Text('SPATIAL_VERIFICATION_BLOCKED'));
    }
    final ready = _current && !_failed && !_stopping && !_hold;
    return Scaffold(
        appBar: AppBar(title: const Text('LOCAL Spatial Audio · 검증 전용')),
        body: SingleChildScrollView(
            child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                          '로컬 생성 4초 테스트 음원. 실제 버스·거리·출입문·Head Tracking 정보가 아닙니다.'),
                      const Text(
                          '헤드폰 좌우 채널을 확인하세요. 자동 재생 없음. TTS는 공간화되지 않습니다.'),
                      const Text(
                          '좌표: listener=(0,0,0), 정면=-Z, 오른쪽=+X, 위=+Y; LEFT=(-1,0,-1), CENTER=(0,0,-1), RIGHT=(1,0,-1). 테스트 임의 단위.'),
                      Text(
                          'epoch=$_epoch · generation=$_generation · current=$_current'),
                      Text(
                          'Engine: ${_probe['phase']} · context=${_probe['contextState']} · active=${_probe['active']} · run=${_probe['runId']}'),
                      if (_failed)
                        const Text('AUDIO_BLOCKED · 새 음원 금지, reload required'),
                      for (final mode in ['STEREO', 'HRTF'])
                        Wrap(spacing: 8, children: [
                          for (final direction in ['CENTER', 'LEFT', 'RIGHT'])
                            ElevatedButton(
                                onPressed:
                                    ready ? () => _play(mode, direction) : null,
                                child: Text('$mode $direction'))
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
                            onPressed: !_stopping
                                ? () => _stop('LOGOUT', end: true)
                                : null,
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
                            onPressed: () {
                              Navigator.of(context).pushReplacement(
                                  MaterialPageRoute<void>(
                                      builder: (_) => const Scaffold(
                                          body: Text('검증 페이지 종료 · 잔여 소리 확인'))));
                            },
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
