import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'direction_pan.dart';
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
    this.beaconName = 'A (…47)',
  });
  final double? z, reference;
  final bool fresh;
  final int sensorAgeMs;
  final int? beaconRssi;
  final DateTime? beaconSeenAt;
  final String beaconName;
  @override
  State<DirectionAudioPanel> createState() => _DirectionAudioPanelState();
}

class _DirectionAudioPanelState extends State<DirectionAudioPanel>
    with WidgetsBindingObserver {
  static const _audio = MethodChannel('mobi.temp/tone');
  bool _playing = false, _starting = false, _syncing = false;
  bool _reverse = false, _disposed = false;
  bool _proximity = true;
  double _objectAngle = 0;
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
      widget.sensorAgeMs < 1000 &&
      widget.z != null &&
      widget.reference != null;
  bool get _ready =>
      _sensorReady &&
      (!_proximity || _beaconFresh) &&
      (_pan?.supported ?? false);
  int get _interval => _proximity && _beaconFresh
      ? beaconToneIntervalMs(widget.beaconRssi!)
      : 1000;
  DirectionPan? get _pan => _sensorReady
      ? _directionTracker.track(
          DirectionPan.fromZ(
            widget.z!,
            widget.reference!,
            reverse: _reverse,
            objectAngle: _objectAngle,
          ),
        )
      : null;
  void _refresh() {
    if (mounted && !_disposed) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _timer = Timer.periodic(
      const Duration(milliseconds: 150),
      (_) => unawaited(_sync()),
    );
  }

  Map<String, Object> _arguments(DirectionPan pan) => {
    'left': pan.left,
    'right': pan.right,
    'sensorAgeMs': widget.sensorAgeMs,
    'intervalMs': _interval,
    'beaconAgeMs': _proximity ? _beaconAge : -1,
  };

  Future<void> _start() async {
    if (!_ready || _playing || _starting) return;
    final generation = ++_generation;
    _starting = true;
    _message = '이어폰 출력 준비 중…';
    _refresh();
    try {
      final result = await _audio.invokeMapMethod<String, dynamic>(
        'start',
        _arguments(_pan!),
      );
      if (_disposed || generation != _generation) return;
      _playing = result?['running'] == true;
      _route = result?['route'] as String? ?? '';
      _message = _playing
          ? '짧은 삐 소리 재생 중 · 최대 30초'
          : (result?['reason'] as String? ?? '시작되지 않았습니다.');
      if (_playing) {
        _duration
          ..reset()
          ..start();
      }
    } catch (e) {
      if (generation == _generation) _message = '재생 시작 실패: $e';
    } finally {
      if (generation == _generation) _starting = false;
      _refresh();
    }
  }

  Future<void> _sync() async {
    if (!_playing || _syncing || _disposed) return;
    if (!_ready) {
      await _stop('수신 상태 또는 목표각을 확인해주세요. 후방 목표는 5방향 출력 범위 밖입니다.');
      return;
    }
    if (_duration.elapsed >= const Duration(seconds: 30)) {
      await _stop('30초 테스트 종료. 다시 시작할 수 있습니다.');
      return;
    }
    _syncing = true;
    final generation = _generation;
    try {
      final result = await _audio.invokeMapMethod<String, dynamic>(
        'update',
        _arguments(_pan!),
      );
      if (generation != _generation || _disposed) return;
      if (result?['running'] != true) {
        _playing = false;
        _message = result?['reason'] as String? ?? '테스트음이 중지됐습니다.';
        _duration.stop();
      }
      _route = result?['route'] as String? ?? '';
    } catch (e) {
      if (generation == _generation) await _stop('출력 상태 확인 실패: $e');
    } finally {
      _syncing = false;
      _refresh();
    }
  }

  Future<void> _stop(String message) async {
    ++_generation;
    _playing = false;
    _starting = false;
    _duration.stop();
    _message = message;
    _refresh();
    try {
      await _audio.invokeMethod<void>('stop');
    } catch (_) {
      // The native watchdog also stops playback if updates stop arriving.
    }
  }

  @override
  void didUpdateWidget(covariant DirectionAudioPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reference != widget.reference || !widget.fresh) {
      _directionTracker.reset();
    }
    if ((_playing || _starting) &&
        (!_ready ||
            oldWidget.reference != widget.reference ||
            oldWidget.beaconName != widget.beaconName)) {
      unawaited(_stop('센서 상태 또는 기준각이 바뀌어 테스트음을 중지했습니다.'));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && (_playing || _starting)) {
      unawaited(_stop('화면을 벗어나 테스트음을 중지했습니다.'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final pan = _pan;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 28),
        Text(
          '5방향 목표 · 방향 테스트음',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const Text(
          '골전도 이어폰을 연결하고 정면을 기준각으로 지정하세요. 비콘 간격 조절은 60초 스캔과 함께 사용하세요. 처음에는 낮은 미디어 음량으로 확인하세요.',
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('비콘에 따라 소리 간격 조절'),
          subtitle: Text('기준 비콘 ${widget.beaconName} · 강한 신호는 짧게, 약한 신호는 길게'),
          value: _proximity,
          onChanged: _playing || _starting
              ? null
              : (v) => setState(() => _proximity = v),
        ),
        Text(
          _proximity
              ? (_beaconFresh
                    ? '비콘 ${widget.beaconName}: ${widget.beaconRssi} dBm · 간격 ${(_interval / 1000).toStringAsFixed(2)}초'
                    : '기준 비콘 수신 대기 · 60초 스캔을 시작해주세요')
              : '간격 조절 꺼짐 · 고정 간격 1초',
        ),
        DropdownButton<double>(
          value: _objectAngle,
          isExpanded: true,
          items: FiveWayCue.values
              .map(
                (cue) => DropdownMenuItem(
                  value: cue.angle,
                  child: Text('수동 목표: ${cue.label} (${cue.angle.round()}°)'),
                ),
              )
              .toList(),
          onChanged: _playing || _starting
              ? null
              : (value) {
                  if (value != null) {
                    setState(() {
                      _directionTracker.reset();
                      _objectAngle = value;
                    });
                  }
                },
        ),
        const Text('목표각은 기준 방향에 대한 수동 입력입니다. Vision/Context 연결은 아직 없습니다.'),
        if (pan != null)
          Text(pan.supported ? '출력 Cue: ${pan.cue.code}' : '후방 목표 · 재생 중지'),
        if (pan != null)
          Text(
            '목표 상대각: ${pan.targetAngle.toStringAsFixed(1)}° · 왼쪽 ${(pan.left * 100).round()}% / 오른쪽 ${(pan.right * 100).round()}%',
          ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('회전 방향 반대로'),
          subtitle: const Text('좌우 변화가 예상과 반대라면 중지 후 변경'),
          value: _reverse,
          onChanged: _playing || _starting
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
              onPressed: _ready && !_playing && !_starting ? _start : null,
              child: const Text('방향음 시작'),
            ),
            OutlinedButton(
              onPressed: _playing || _starting
                  ? () => unawaited(_stop('사용자가 테스트음을 중지했습니다.'))
                  : null,
              child: const Text('소리 중지'),
            ),
          ],
        ),
        const Text(
          '좌우 음량 비교용입니다. 앞/뒤 구분이나 HRTF 3D 음향은 구현하지 않았으며 비콘 방향을 추정하지 않습니다.',
        ),
      ],
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    if (_playing || _starting) unawaited(_stop(''));
    super.dispose();
  }
}
