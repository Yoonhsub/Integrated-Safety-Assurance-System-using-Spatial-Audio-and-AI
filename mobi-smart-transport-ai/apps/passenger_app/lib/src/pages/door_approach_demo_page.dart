import 'dart:async';
import 'package:flutter/material.dart';
import 'package:mobi_mobile_sensors/mobi_mobile_sensors.dart';
import '../services/door_approach_guard.dart';
import '../services/door_input_adapter.dart';
import '../services/door_vision_policy.dart';
import '../services/directional_guidance.dart';
import '../services/spatial_verification_engine.dart';
import '../services/speech_priority_coordinator.dart';

class DoorCameraInput {
  const DoorCameraInput(
      {required this.onFrame,
      required this.onUnavailable,
      required this.now,
      required this.isCurrent});
  final void Function(Map<String, Object?> result, Duration capturedAt) onFrame;
  final VoidCallback onUnavailable;
  final Duration Function() now;
  final bool Function() isCurrent;
}

/// Explicit local demo. Native camera risk is an opt-in rehearsal caution rule.
class DoorApproachDemoPage extends StatefulWidget {
  const DoorApproachDemoPage(
      {super.key,
      required this.output,
      required this.tts,
      this.sessionNow,
      this.targetId = 'DEMO_DOOR_A',
      this.scannerFactory,
      this.prepareScanner,
      this.transportStops,
      this.audioStops,
      this.beforeGuidanceStart,
      this.cameraBuilder,
      this.wallNow});
  final SpatialTestOutput output;
  final SpeechEngine tts;
  final Duration Function()? sessionNow;
  final String targetId;
  final BeaconScanner Function()? scannerFactory;
  final Future<bool> Function()? prepareScanner;
  final Stream<void>? transportStops;
  final Stream<void>? audioStops;
  final Future<bool> Function()? beforeGuidanceStart;
  final DateTime Function()? wallNow;
  final Widget Function(DoorCameraInput input)? cameraBuilder;
  @override
  State<DoorApproachDemoPage> createState() => _DoorDemoState();
}

class _DoorDemoState extends State<DoorApproachDemoPage>
    with WidgetsBindingObserver {
  final _clock = Stopwatch()..start();
  final _visionJson = TextEditingController();
  String _visionStatus = '기록 탐지 입력 없음';
  DoorVisionPolicy _cameraPolicy = DoorVisionPolicy();
  bool _cameraEnabled = false;
  int _cameraEpoch = 0;
  String _cameraStatus = '카메라 입력 없음';

  void _setCamera(bool enabled) {
    ++_cameraEpoch;
    _cameraEnabled = enabled;
    _perceptionReplay = false;
    _cameraPolicy = DoorVisionPolicy();
    _guard.invalidatePerception(_now);
    _cameraStatus = enabled ? '새 실측 카메라 프레임 대기' : '카메라 미사용';
    _tick();
  }

  Widget _camera() {
    final epoch = _cameraEpoch;
    bool current() =>
        !_closed && !_failed && _cameraEnabled && epoch == _cameraEpoch;
    return SizedBox(
        height: 560,
        child: KeyedSubtree(
            key: ValueKey(epoch),
            child: widget.cameraBuilder!(DoorCameraInput(
                now: () => _now,
                isCurrent: current,
                onUnavailable: () {
                  if (!current()) return;
                  _guard.invalidatePerception(_now);
                  _cameraStatus = '카메라 중지/사용 불가 · 접근 보류';
                  _tick();
                },
                onFrame: (result, capture) {
                  if (!current()) return;
                  final now = _now;
                  try {
                    final obstacles = _cameraPolicy.evaluate(result,
                        capturedAt: capture, now: now);
                    _guard.observeObstacles(
                        at: capture, now: now, obstacles: obstacles);
                    _cameraStatus =
                        '탐지: 실측 · 위험도: 시연 주의 규칙 · frame=${result['frameId']} · capture_us=${capture.inMicroseconds} · 장애물 ${obstacles.length}개';
                  } catch (error) {
                    _guard.invalidatePerception(now);
                    _cameraStatus = '카메라 입력 거부 · 접근 보류: $error';
                  }
                  _tick();
                }))));
  }

  Duration get _now => widget.sessionNow?.call() ?? _clock.elapsed;
  late final DoorApproachGuard _guard;
  late final DoorBeaconInput _beaconInput;
  BeaconScanner? _scanner;
  StreamSubscription<BeaconSignal>? _scanSubscription;
  StreamSubscription<void>? _transportSubscription;
  StreamSubscription<void>? _audioSubscription;
  String _startIssue = '';
  bool _scanning = false, _scanBusy = false, _scanStopping = false;
  int _scanEpoch = 0;
  String _scanStatus = '스캔 미실행';
  bool get _realBle => widget.scannerFactory != null;
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
    _guard = DoorApproachGuard(targetId: widget.targetId);
    _beaconInput = DoorBeaconInput(_guard);
    _audioSubscription = widget.audioStops?.listen((_) {
      unawaited(_endScan('이어폰 연결 해제 · 안내 중지 · 재연결 후 수동 시작 필요'));
    }, onError: (Object _) {
      unawaited(_endScan('이어폰 상태 확인 실패 · 안내 중지'));
    });
    _transportSubscription = widget.transportStops?.listen((_) {
      unawaited(_endScan('Bluetooth 상태 변경 · 안내 중지'));
    }, onError: (Object error) {
      unawaited(_endScan('Bluetooth 상태 확인 실패 · 안내 중지'));
    });
    WidgetsBinding.instance.addObserver(this);
    _engine = SpatialVerificationEngine(widget.output, widget.tts);
    _speech = SpeechPriorityCoordinator(_engine);
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) => _tick());
  }

  Future<void> _startScan() async {
    if (_closed || _failed || _scanBusy || _scanning || _scanStopping) return;
    final epoch = ++_scanEpoch;
    setState(() => _scanBusy = true);
    try {
      if (!(await widget.prepareScanner?.call() ?? false)) {
        if (epoch == _scanEpoch) {
          _scanStatus = '주변 기기·정확한 위치 권한, Bluetooth와 위치 기능을 확인해주세요';
        }
        return;
      }
      if (_closed || _failed || epoch != _scanEpoch) return;
      final scanner = widget.scannerFactory!();
      _scanner = scanner;
      _scanning = true;
      _scanStatus = '실측 스캔 중 · 서버 전송 미실행';
      _scanSubscription = scanner.scan().listen((signal) {
        if (_closed || epoch != _scanEpoch || !_scanning) return;
        final accepted = _beaconInput.observe(signal,
            wallNow: widget.wallNow?.call() ?? DateTime.now(), now: _now);
        if (accepted) {
          _scanStatus =
              '실측 ${signal.beaconId} · 평활 RSSI ${signal.rssi} · ${signal.signalLevel.name} · 원본 관측 ${signal.lastDetectedAt.toUtc().toIso8601String()}';
        }
        _tick();
      }, onError: (Object error) {
        if (epoch == _scanEpoch) unawaited(_endScan('스캔 실패 · 안내 중지: $error'));
      }, onDone: () {
        if (epoch == _scanEpoch) unawaited(_endScan('스캔 종료 · 안내 중지'));
      });
    } catch (error) {
      if (epoch == _scanEpoch) await _endScan('스캔 시작 실패: $error');
    } finally {
      if (!_closed && mounted) setState(() => _scanBusy = false);
    }
  }

  Future<void> _endScan(String reason) async {
    if (_scanStopping) return;
    _scanStopping = true;
    ++_scanEpoch;
    ++_gestureEpoch;
    _scanning = false;
    _cameraEnabled = false;
    ++_cameraEpoch;
    _targetReplay = _perceptionReplay = false;
    _scanStatus = reason;
    final scanner = _scanner, subscription = _scanSubscription;
    _scanner = null;
    _scanSubscription = null;
    if (!_closed) {
      _guard.stop(_now);
      _tick(); // Retire audio immediately, before waiting for the BLE transport.
    }
    try {
      await scanner?.stop().timeout(const Duration(seconds: 3));
      await subscription?.cancel().timeout(const Duration(seconds: 3));
    } catch (error) {
      _fault(error);
    } finally {
      _scanStopping = false;
      if (!_closed && mounted) setState(() {});
    }
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
          id: widget.targetId,
          at: now,
          now: now,
          proximity: _near ? DoorProximity.near : DoorProximity.approaching);
    }
    final frame = _guard.tick(now);
    if (frame.key != _lastKey) {
      _lastKey = frame.key;
      if (_realBle) {
        debugPrint(
            'MOBI_DOOR_STATE at_us=${now.inMicroseconds} target=${widget.targetId} phase=${frame.phase.name} risk=${_cameraEnabled ? "CAMERA_DEMO_CAUTION" : "MOCK_OR_REPLAY"} text=${frame.text}');
      }
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
    if (_realBle) unawaited(_endScan('출력 실패 · 스캔 중지'));
    unawaited(_engine.stop().catchError((Object _) {}));
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      ++_gestureEpoch;
      _guard.stop(_now);
      _targetReplay = _perceptionReplay = false;
      if (_realBle) unawaited(_endScan('화면 이탈 · 재시작 필요'));
      _tick();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('탑승문 접근 · 중단 조건 리플레이')),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        Text('목표 버스 선택 완료 · 목표 문 ${widget.targetId}'),
        Text(_realBle
            ? '비콘: 실측 · 위험도: ${_cameraEnabled ? "카메라 탐지 기반 시연 주의 규칙" : "모의/기록 재생"} · 머리 추적 미사용 · 서버 판정 미실행'
            : '입력: 모의 · 실제 BLE/AI/머리 추적 연결은 아직 없습니다. 서버 판정 미실행.'),
        if (_realBle) ...[
          Text(_scanStatus),
          OutlinedButton(
              onPressed: _failed || _scanning || _scanBusy || _scanStopping
                  ? null
                  : _startScan,
              child: const Text('실측 BLE 스캔 시작 (5분)')),
        ],
        const Text('방향은 화면 기준 좌우 스테레오입니다. 비콘으로 문 방향·문 열림·발밑 안전을 판단하지 않습니다.'),
        const SizedBox(height: 16),
        Text(_guard.current.text,
            style: Theme.of(context).textTheme.headlineSmall),
        Text('상태: ${_guard.current.phase.name}'),
        Text(_outputStatus),
        if (_startIssue.isNotEmpty) Text(_startIssue),
        Wrap(spacing: 8, children: [
          FilledButton(
              onPressed: _failed || (_realBle && !_scanning)
                  ? null
                  : () async {
                      final gesture = ++_gestureEpoch;
                      try {
                        final ready =
                            await widget.beforeGuidanceStart?.call() ?? true;
                        if (_closed || _failed || gesture != _gestureEpoch) {
                          return;
                        }
                        if (!ready) {
                          _startIssue =
                              '이어폰 미디어 연결 필요 · 안내 중지. 연결 후 안내 시작을 다시 눌러주세요.';
                          _guard.stop(_now);
                          _tick();
                          return;
                        }
                        _startIssue = '';
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
                _targetReplay = _perceptionReplay = false;
                if (_realBle) unawaited(_endScan('사용자 STOP · 재시작 필요'));
                _tick();
              },
              child: const Text('STOP')),
        ]),
        if (!_realBle)
          SwitchListTile(
              title: const Text('새 목표 비콘 관측 모의 재생'),
              value: _targetReplay,
              onChanged: _failed
                  ? null
                  : (v) {
                      setState(() => _targetReplay = v);
                      _tick();
                    }),
        Text(_realBle
            ? '3초간 새 목표 관측이 없으면 접근 안내를 중단합니다. 다른 비콘은 목표를 갱신하지 않습니다.'
            : '재생을 끄면 마지막 관측 시각을 갱신하지 않습니다. 3초 후 접근 안내가 중단됩니다.'),
        if (!_realBle)
          SwitchListTile(
              title: const Text('모의 근접 구간: 가까움'),
              value: _near,
              onChanged: (v) {
                setState(() => _near = v);
                _tick();
              }),
        if (widget.cameraBuilder != null) ...[
          SwitchListTile(
              title: const Text('실측 카메라 장애물 규칙 사용'),
              subtitle: const Text('킥보드·기둥·나무 → 시연 주의. 충돌 위험도·거리·경로 안전 미측정.'),
              value: _cameraEnabled,
              onChanged: _failed ? null : _setCamera),
          Text(_cameraStatus),
          if (_cameraEnabled) _camera(),
        ],
        SwitchListTile(
            title: const Text('새 장애물 전체 스냅샷 모의 재생'),
            value: _perceptionReplay,
            onChanged: _failed || _cameraEnabled
                ? null
                : (v) {
                    setState(() => _perceptionReplay = v);
                    _tick();
                  }),
        const Text('위험 정보도 2초간 새 관측이 없으면 안내를 중단합니다.'),
        ExpansionTile(title: const Text('AI 탐지 JSON 한 프레임 재생'), children: [
          const Text(
              '입력: 기록 재생 · 위험도: 아래에서 선택한 모의 값. 원본 capturedAt은 보존하며 실시간 카메라로 표시하지 않습니다. 각 클릭은 1회 재생이고 2초 뒤 만료됩니다.'),
          TextField(
              controller: _visionJson,
              maxLines: 5,
              decoration:
                  const InputDecoration(labelText: 'vision_detection 응답 JSON')),
          OutlinedButton(
              onPressed: _failed || _cameraEnabled
                  ? null
                  : () {
                      _perceptionReplay = false;
                      final now = _now;
                      try {
                        final replay = DoorVisionReplay.parse(_visionJson.text,
                            testRisk: _risk);
                        _guard.observeObstacles(
                            at: now, now: now, obstacles: replay.obstacles);
                        _visionStatus =
                            '기록 재생: ${replay.frameId} · 원본 ${replay.originalSource} · 촬영 ${replay.capturedAt ?? "미상"} · 위험도 모의 ${_risk.name}';
                      } catch (error) {
                        _guard.observeObstacles(
                            at: now,
                            now: now,
                            obstacles: const [
                              DoorObstacle('invalid', DoorRisk.danger, pan: 2)
                            ]);
                        _guard.stop(now);
                        _visionStatus = '입력 거부 · 접근 중단: $error';
                      }
                      _tick();
                    },
              child: const Text('탐지 스냅샷 1회 재생')),
          Text(_visionStatus),
        ]),
        DropdownButton<DoorRisk>(
            value: _risk,
            items: DoorRisk.values
                .map((v) =>
                    DropdownMenuItem(value: v, child: Text('모의 위험: ${v.name}')))
                .toList(),
            onChanged: _cameraEnabled
                ? null
                : (v) {
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
            onChanged: _cameraEnabled
                ? null
                : (v) {
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
    unawaited(_endScan('페이지 종료'));
    unawaited(_transportSubscription?.cancel());
    unawaited(_audioSubscription?.cancel());
    ++_gestureEpoch;
    ++_revision;
    _timer?.cancel();
    _visionJson.dispose();
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_engine.dispose().catchError((Object _) {}).whenComplete(() {
      _lease?.release();
      _speech.dispose();
    }));
    super.dispose();
  }
}
