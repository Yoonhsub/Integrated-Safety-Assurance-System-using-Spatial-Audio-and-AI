import 'dart:async';
import 'package:flutter/material.dart';
import '../services/door_approach_guard.dart';
import '../services/directional_guidance.dart';
import '../services/spatial_verification_engine.dart';
import '../services/speech_priority_coordinator.dart';

/// Explicit replay harness. No BLE receiver, AI detector or vehicle registry.
class DoorApproachDemoPage extends StatefulWidget {
  const DoorApproachDemoPage(
      {super.key, required this.output, required this.tts, this.sessionNow});
  final SpatialTestOutput output;
  final SpeechEngine tts;
  final Duration Function()? sessionNow;
  @override
  State<DoorApproachDemoPage> createState() => _DoorDemoState();
}

class _DoorDemoState extends State<DoorApproachDemoPage>
    with WidgetsBindingObserver {
  final _clock = Stopwatch()..start();
  Duration get _now => widget.sessionNow?.call() ?? _clock.elapsed;
  final _guard = DoorApproachGuard(targetId: 'DEMO_DOOR_A');
  final _owner = Object();
  late final SpatialVerificationEngine _engine;
  late final SpeechPriorityCoordinator _speech;
  Timer? _timer;
  Future<void> _tail = Future.value();
  PriorityLease? _lease;
  bool _targetReplay = false, _perceptionReplay = false, _near = false;
  DoorRisk _risk = DoorRisk.none;
  double? _pan = 0;
  String _lastKey = '', _outputStatus = '청취 미확인 · 자동 재생 없음';
  int _revision = 0;
  int _gestureEpoch = 0;
  bool _closed = false, _failed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _engine = SpatialVerificationEngine(widget.output, widget.tts);
    _speech = SpeechPriorityCoordinator(_engine);
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) => _tick());
  }

  void _tick() {
    if (_closed) return;
    final now = _now;
    if (_perceptionReplay) {
      _guard.observeObstacles(
          at: now,
          now: now,
          obstacles: _risk == DoorRisk.none
              ? const []
              : [DoorObstacle('모의 장애물', _risk, pan: _pan)]);
    }
    if (_targetReplay) {
      _guard.observeTarget(
          id: 'DEMO_DOOR_A',
          at: now,
          now: now,
          proximity: _near ? DoorProximity.near : DoorProximity.approaching);
    }
    final frame = _guard.tick(now);
    if (frame.key != _lastKey) {
      _lastKey = frame.key;
      _render(frame);
    }
    if (mounted) setState(() {});
  }

  bool _valid(int revision, DoorGuidance frame) =>
      !_closed &&
      !_failed &&
      revision == _revision &&
      _guard.tick(_now).key == frame.key;

  void _render(DoorGuidance frame) {
    final revision = ++_revision; // Retire pending starts before async cleanup.
    _tail = _tail.then<void>((_) async {
      await Future.wait(
          [_speech.stopObservation(_owner), _speech.stopPriority(_owner)]);
      await _engine.stop().timeout(const Duration(seconds: 3));
      _lease?.release();
      _lease = null;
      if (_valid(revision, frame)) _outputStatus = '출력 중지 확인 · 실제 청취는 별도 확인';
      if (!_valid(revision, frame) ||
          frame.phase == DoorPhase.stopped ||
          frame.phase == DoorPhase.arrived ||
          frame.phase == DoorPhase.awaitingTarget) {
        return;
      }
      final warning = frame.phase == DoorPhase.warning;
      if (warning) _lease = _speech.claimPriority();
      final direction = frame.pan == null
          ? null
          : frame.pan! < -.33
              ? TestDirection.left
              : frame.pan! > .33
                  ? TestDirection.right
                  : TestDirection.center;
      final command = _engine.registerGuidance(
          DirectionalGuidance(
              guidanceId: 'door-$revision',
              sessionGeneration: 'local-replay',
              authEpoch: 0,
              priority: GuidancePriority.observation,
              text: frame.text,
              provenance: DirectionalGuidance.syntheticProvenance,
              testDirection: direction,
              directionEvidence: DirectionEvidence.explicitLocalFixture),
          () => _valid(revision, frame));
      if (command == null) return;
      _outputStatus = '출력 요청 · 실제 청취는 별도 확인';
      final playing = warning
          ? _speech.speakPriority(
              _owner, command, () => _valid(revision, frame))
          : _speech.speakObservation(
              _owner, command, () => _valid(revision, frame));
      unawaited(playing.then((_) => _engine.retireGuidance(command),
          onError: (Object error, StackTrace stack) {
        _engine.retireGuidance(command);
        if (_valid(revision, frame)) _fault(error);
      }));
    }).catchError((Object error) => _fault(error));
  }

  void _fault(Object error) {
    if (_closed || _failed) return;
    _failed = true;
    ++_revision;
    _guard.stop(_now);
    _outputStatus = '출력 실패 · 안내 중지 · 페이지를 다시 열어주세요';
    unawaited(_engine.stop().catchError((Object _) {}));
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      ++_gestureEpoch;
      _guard.stop(_now);
      _targetReplay = _perceptionReplay = false;
      _tick();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('탑승문 접근 · 중단 조건 리플레이')),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        const Text('목표 버스 선택 완료 · 목표 문 DEMO_DOOR_A'),
        const Text('입력: 모의 · 실제 BLE/AI/머리 추적 연결은 아직 없습니다. 서버 판정 미실행.'),
        const Text('방향은 화면 기준 좌우 스테레오입니다. 비콘으로 문 방향·문 열림·발밑 안전을 판단하지 않습니다.'),
        const SizedBox(height: 16),
        Text(_guard.current.text,
            style: Theme.of(context).textTheme.headlineSmall),
        Text('상태: ${_guard.current.phase.name}'),
        Text(_outputStatus),
        Wrap(spacing: 8, children: [
          FilledButton(
              onPressed: _failed
                  ? null
                  : () async {
                      final gesture = ++_gestureEpoch;
                      try {
                        await widget.output.prepareFromGesture();
                        if (!_closed && !_failed && gesture == _gestureEpoch) {
                          _guard.start(_now);
                          _tick();
                        }
                      } catch (error) {
                        _fault(error);
                      }
                    },
              child: const Text('안내 시작')),
          OutlinedButton(
              onPressed: () {
                ++_gestureEpoch;
                _guard.stop(_now);
                _tick();
              },
              child: const Text('STOP')),
        ]),
        SwitchListTile(
            title: const Text('새 목표 비콘 관측 모의 재생'),
            value: _targetReplay,
            onChanged: _failed
                ? null
                : (v) {
                    setState(() => _targetReplay = v);
                    _tick();
                  }),
        const Text('재생을 끄면 마지막 관측 시각을 갱신하지 않습니다. 3초 후 접근 안내가 중단됩니다.'),
        SwitchListTile(
            title: const Text('모의 근접 구간: 가까움'),
            value: _near,
            onChanged: (v) {
              setState(() => _near = v);
              _tick();
            }),
        SwitchListTile(
            title: const Text('새 장애물 전체 스냅샷 모의 재생'),
            value: _perceptionReplay,
            onChanged: _failed
                ? null
                : (v) {
                    setState(() => _perceptionReplay = v);
                    _tick();
                  }),
        const Text('위험 정보도 2초간 새 관측이 없으면 안내를 중단합니다.'),
        DropdownButton<DoorRisk>(
            value: _risk,
            items: DoorRisk.values
                .map((v) =>
                    DropdownMenuItem(value: v, child: Text('모의 위험: ${v.name}')))
                .toList(),
            onChanged: (v) {
              if (v != null) {
                setState(() => _risk = v);
                _tick();
              }
            }),
        DropdownButton<double>(
            value: _pan ?? 2,
            items: const [
              DropdownMenuItem(value: -1, child: Text('모의 장애물: 왼쪽')),
              DropdownMenuItem(value: 0, child: Text('모의 장애물: 중앙')),
              DropdownMenuItem(value: 1, child: Text('모의 장애물: 오른쪽')),
              DropdownMenuItem(value: 2, child: Text('방향 불명 → 중앙 경고')),
            ],
            onChanged: (v) {
              setState(() => _pan = v == 2 ? null : v);
              _tick();
            }),
        OutlinedButton(
            onPressed: _guard.current.phase != DoorPhase.near
                ? null
                : () {
                    _guard.confirmArrival(_now);
                    _tick();
                  },
            child: const Text('시연자 도착 확인')),
        const Text('경고를 해제해도 해제 후 새 목표 관측이 있어야 접근 안내를 재개합니다.'),
      ]));

  @override
  void dispose() {
    _closed = true;
    ++_gestureEpoch;
    ++_revision;
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_engine.dispose().catchError((Object _) {}).whenComplete(() {
      _lease?.release();
      _speech.dispose();
    }));
    super.dispose();
  }
}
