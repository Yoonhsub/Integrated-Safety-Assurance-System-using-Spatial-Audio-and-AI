import 'dart:async';
import 'package:flutter/material.dart';
import 'cue_control.dart';
import 'obstacle_cue_input.dart';
import 'native_cue_output.dart';
import 'direction_pan.dart';
import 'wit_sensor_protocol.dart';
import 'beacon_tone_interval.dart';

class DirectionAudioPanel extends StatefulWidget {
  const DirectionAudioPanel({
    super.key,
    required this.z,
    required this.reference,
    required this.fresh,
    required this.sensorAgeMs,
    this.beaconRssi,
    this.beaconSeenAt,
    this.beaconName = '버스 A',
    this.busAngle = -90,
    this.warning = false,
    this.busEnabled = true,
    this.audioScope = '',
    this.targetIsHeadRelative = false,
    this.waitForTarget = false,
    this.obstacles,
    this.sessionNow,
  });
  final double? z, reference;
  final bool fresh;
  final int sensorAgeMs;
  final int? beaconRssi;
  final DateTime? beaconSeenAt;
  final String beaconName;
  final double busAngle;
  final bool warning, busEnabled;
  final String audioScope;
  final bool targetIsHeadRelative;
  final bool waitForTarget;

  /// Optional producer snapshot; no detector or synthetic input is created here.
  final ObstacleCueSnapshot? obstacles;

  /// Required with obstacles: the same monotonic clock as snapshot capture time.
  final Duration Function()? sessionNow;
  @override
  State<DirectionAudioPanel> createState() => _DirectionAudioPanelState();
}

class _DirectionAudioPanelState extends State<DirectionAudioPanel>
    with WidgetsBindingObserver {
  final _controller = CueController();
  final _clock = Stopwatch()..start();
  late final NativeCueOutput _output;
  late final CueOutputDriver _driver;
  bool get _manualWarning => widget.warning;
  bool _playing = false, _starting = false, _syncing = false;
  bool _waiting = false;
  final _listenDuration = Stopwatch();
  bool _reverse = false, _disposed = false;
  final bool _proximity = true;
  double get _objectAngle => widget.busAngle;
  final _directionTracker = DirectionCueTracker();
  int _generation = 0;
  String _message = '정면을 보고 위의 기준각 버튼을 누른 뒤 시작하세요.';
  String _route = '';
  Timer? _timer;
  final _duration = Stopwatch();

  int get _beaconAge => widget.beaconSeenAt == null
      ? 99999
      : DateTime.now().difference(widget.beaconSeenAt!).inMilliseconds;
  bool get _beaconFresh =>
      widget.beaconRssi != null && _beaconAge >= 0 && _beaconAge < 3000;
  bool get _sensorReady =>
      widget.fresh &&
      widget.sensorAgeMs >= 0 &&
      widget.sensorAgeMs < 1000 &&
      widget.z != null &&
      widget.reference != null &&
      widget.z!.isFinite &&
      widget.reference!.isFinite;
  Duration get _now => widget.sessionNow?.call() ?? _clock.elapsed;
  bool get _externalWarning => _controller.active?.object.obstacleRisk != null;
  String get _playingMessage => _externalWarning
      ? '장애물 공간 경고음 · 센서 방향 보정 중'
      : _manualWarning
          ? '예시 경고음 재생 중'
          : '실제 비콘 간격 · 센서 방향 보정 중';
  CueSelection? get _preview {
    final now = _now;
    return CueController()
        .tick(
          now: now,
          context: CueContext.walking,
          headYaw: widget.targetIsHeadRelative ? 0 : widget.z ?? double.nan,
          reference:
              widget.targetIsHeadRelative ? 0 : widget.reference ?? double.nan,
          reverse: widget.targetIsHeadRelative ? false : _reverse,
          inputReady: _sensorReady,
          objects: _objects(now),
        )
        .selection;
  }

  bool get _ready => _preview != null;

  int get _interval => _proximity && _beaconFresh
      ? beaconToneIntervalMs(widget.beaconRssi!)
      : 1000;
  DirectionPan? get _rawPan => _sensorReady
      ? DirectionPan.fromZ(widget.targetIsHeadRelative ? 0 : widget.z!,
          widget.targetIsHeadRelative ? 0 : widget.reference!,
          reverse: widget.targetIsHeadRelative ? false : _reverse,
          objectAngle: _objectAngle)
      : null;
  bool get _warningBehind => _manualWarning && _rawPan?.supported == false;
  DirectionPan? get _pan {
    final raw = _rawPan;
    if (raw == null) return null;
    if (raw.supported == false) {
      _directionTracker.reset();
      // Keep the true angle for UI; an out-of-field hazard uses a balanced alert.
      return DirectionPan(
          raw.targetAngle, 0, .7071067811865476, .7071067811865476);
    }
    return _directionTracker.track(raw);
  }

  void _refresh() {
    if (mounted && !_disposed) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _output = NativeCueOutput(
      () => ToneInput(
        widget.sensorAgeMs,
        _proximity ? _beaconAge : -1,
        _interval,
      ),
    );
    _driver = CueOutputDriver(_output);
    _timer = Timer.periodic(
      const Duration(milliseconds: 150),
      (_) => unawaited(_sync()),
    );
  }

  CueDecision _decision() {
    final now = _now;
    return _controller.tick(
      now: now,
      context: CueContext.walking,
      headYaw: widget.targetIsHeadRelative ? 0 : widget.z ?? double.nan,
      reference:
          widget.targetIsHeadRelative ? 0 : widget.reference ?? double.nan,
      reverse: widget.targetIsHeadRelative ? false : _reverse,
      inputReady: _sensorReady,
      objects: _objects(now),
    );
  }

  List<CueObject> _objects(Duration now) {
    List<CueObject> obstacles = const [];
    if (widget.obstacles != null && widget.sessionNow != null) {
      try {
        obstacles = widget.obstacles!.toCueObjects();
      } on ArgumentError {
        // Reject invalid snapshots; never retain an older warning as fallback.
      }
    }
    return [
      ...obstacles,
      if (widget.busEnabled && _beaconFresh) ...[
        CueObject(
          id: 'manual-target',
          kind: CueObjectKind.target,
          distance: CueDistance.near,
          angleDegrees: _objectAngle,
          observedAt: now,
        ),
        if (_manualWarning && _sensorReady)
          CueObject(
            id: 'manual-warning',
            kind: CueObjectKind.obstacle,
            distance: CueDistance.near,
            angleDegrees: _warningBehind
                ? relativeAngle(widget.z!, widget.reference!) *
                    (_reverse ? -1 : 1)
                : _objectAngle,
            observedAt: now,
          ),
      ],
    ];
  }

  Future<void> _requestStart() async {
    if (widget.waitForTarget) {
      _listenDuration
        ..reset()
        ..start();
      if (!_ready) {
        _waiting = true;
        _message = '소리 대기 중 · 문 검출과 카메라·센서·목표 비콘의 최신 입력을 기다립니다.';
        _refresh();
        return;
      }
    }
    await _start();
  }

  Future<void> _start() async {
    if (!_ready || _playing || _starting) return;
    final generation = ++_generation;
    _starting = true;
    _controller.reset();
    _controller.resume();
    _message = '이어폰 출력 준비 중…';
    _refresh();
    try {
      await _driver.apply(_decision());
      if (_disposed || generation != _generation) return;
      _playing = _output.running;
      _route = _output.route;
      _message = _playingMessage;
      if (_playing) {
        _duration
          ..reset()
          ..start();
      }
    } catch (e) {
      if (generation == _generation) await _stop('재생 시작 실패: $e');
    } finally {
      if (generation == _generation) _starting = false;
      _refresh();
    }
  }

  Future<void> _sync() async {
    if (_disposed) return;
    if (widget.waitForTarget &&
        _listenDuration.isRunning &&
        _listenDuration.elapsed >= const Duration(minutes: 5)) {
      await _stop('5분 소리 대기·안내 종료. 다시 시작할 수 있습니다.');
      return;
    }
    if (_waiting) {
      if (_ready) {
        _waiting = false;
        await _start();
      }
      return;
    }
    if (!_playing || _syncing || _disposed) return;
    if (!_ready) {
      await _stop(
          widget.waitForTarget && _sensorReady && _beaconFresh
              ? '소리 대기 중 · 문을 다시 확인하면 재생합니다.'
              : '센서 또는 비콘의 최신 수신 상태를 확인해주세요.',
          wait: widget.waitForTarget && _sensorReady && _beaconFresh);
      return;
    }
    if (_duration.elapsed >= const Duration(minutes: 5)) {
      await _stop('5분 안내 종료. 다시 시작할 수 있습니다.');
      return;
    }
    _syncing = true;
    final generation = _generation;
    try {
      final decision = _decision();
      // Refresh native source-age/route watchdog even for an unchanged cue.
      await _driver.apply(
        decision.action == CueAction.none && decision.selection != null
            ? CueDecision(
                CueAction.update,
                decision.selection,
                'source heartbeat',
              )
            : decision,
      );
      if (generation != _generation || _disposed) return;
      if (!_output.running) {
        await _stop(_output.reason);
        return;
      }
      _route = _output.route;
      _message = _playingMessage;
    } catch (e) {
      if (generation == _generation) await _stop('출력 상태 확인 실패: $e');
    } finally {
      _syncing = false;
      _refresh();
    }
  }

  Future<void> _stop(String message, {bool wait = false}) async {
    ++_generation;
    _playing = false;
    _starting = false;
    _waiting = wait;
    if (!wait) _listenDuration.stop();

    _controller.cancel();
    _duration.stop();
    _message = message;
    _refresh();
    try {
      // Force a stop even if a start is still in flight or policy was inactive.
      await _driver.apply(
        const CueDecision(CueAction.stop, null, 'explicit stop'),
      );
    } catch (_) {
      // Native watchdog also stops if heartbeat stops arriving.
    }
  }

  @override
  void didUpdateWidget(covariant DirectionAudioPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reference != widget.reference || !widget.fresh) {
      _directionTracker.reset();
    }
    final scopeChanged = oldWidget.beaconName != widget.beaconName ||
        oldWidget.audioScope != widget.audioScope;
    if (_waiting && scopeChanged) {
      unawaited(_stop('목표 또는 시험 세션이 바뀌어 소리 대기를 취소했습니다.'));
    } else if ((_playing || _starting) &&
        (!_ready ||
            oldWidget.reference != widget.reference ||
            (!_externalWarning && scopeChanged))) {
      final wait = widget.waitForTarget &&
          !scopeChanged &&
          oldWidget.reference == widget.reference &&
          _sensorReady &&
          _beaconFresh;
      unawaited(_stop(
          wait ? '소리 대기 중 · 문을 다시 확인하면 재생합니다.' : '입력 상태가 바뀌어 테스트음을 중지했습니다.',
          wait: wait));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed &&
        (_playing || _starting || _waiting)) {
      unawaited(_stop('화면을 벗어나 테스트음을 중지했습니다.'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final displayed = _playing ? _controller.active : _preview;
    final spatial = displayed?.usesHrtf ?? false;
    final pan = spatial
        ? displayed?.direction
        : _warningBehind
            ? _pan
            : (_playing ? _controller.active?.direction ?? _pan : _pan);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 28),
        Text(
          '버스·장애물 방향 안내',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const Text(
          '골전도 이어폰을 연결하고 도로 정면에서 기준을 설정하세요. 버스 또는 장애물 입력이 있을 때 소리를 시작하세요.',
        ),
        if (widget.busEnabled)
          Text(
            _proximity
                ? (_beaconFresh
                    ? '비콘 ${widget.beaconName}: ${widget.beaconRssi} dBm · 간격 ${(_interval / 1000).toStringAsFixed(2)}초'
                    : '버스 비콘 수신 대기 · 버스 탐색을 시작해주세요')
                : '간격 조절 꺼짐 · 고정 간격 1초',
          ),
        if (widget.busEnabled && !widget.targetIsHeadRelative)
          Text('도로 기준 버스 방향: ${widget.busAngle.toStringAsFixed(0)}°'),
        if (pan != null)
          Text(spatial
              ? (pan.targetAngle.abs() > 95
                  ? '후방 장애물 · 공간 경고음'
                  : '장애물 · 공간 경고음')
              : _warningBehind
                  ? '후방 대상 · 방향 없는 경고음'
                  : pan.supported
                      ? (!_manualWarning && _rawPan?.supported == false
                          ? '후방 목표 · 방향 없는 중앙 근접음'
                          : '출력 Cue: ${pan.cue.code}')
                      : '후방 목표 · 재생 중지'),
        if (pan != null)
          Text(
            spatial
                ? '장애물 상대 방향: ${pan.targetAngle.toStringAsFixed(1)}° (정면 0° · 오른쪽 +90° · 후방 ±180°)'
                : '목표 상대각: ${pan.targetAngle.toStringAsFixed(1)}° · 왼쪽 ${(pan.left * 100).round()}% / 오른쪽 ${(pan.right * 100).round()}%',
          ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('회전 방향 반대로'),
          subtitle: const Text('좌우 변화가 예상과 반대라면 중지 후 변경'),
          value: _reverse,
          onChanged: widget.targetIsHeadRelative || _playing || _starting
              ? null
              : (v) => setState(() {
                    _directionTracker.reset();
                    _reverse = v;
                  }),
        ),
        Text(_message),
        if (_route.isNotEmpty) Text('출력: $_route'),
        Wrap(
          spacing: 8,
          children: [
            FilledButton(
              onPressed: (_ready || widget.waitForTarget) &&
                      !_playing &&
                      !_starting &&
                      !_waiting
                  ? _requestStart
                  : null,
              child: Text(widget.obstacles != null ? '안내 소리 시작' : '버스 소리 시작'),
            ),
            OutlinedButton(
              onPressed: _playing || _starting || _waiting
                  ? () => unawaited(_stop('사용자가 테스트음을 중지했습니다.'))
                  : null,
              child: const Text('소리 중지'),
            ),
          ],
        ),
        if (widget.busEnabled && !widget.targetIsHeadRelative)
          const Text(
            '방향은 왼쪽 접근→정면 정차→오른쪽 출발 가정을 따릅니다. 비콘 방위를 측정하지 않습니다. 후방 목표는 중앙 근접음으로 계속 재생합니다.',
          ),
      ],
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    if (_playing || _starting || _waiting) unawaited(_stop(''));
    super.dispose();
  }
}
