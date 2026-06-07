import 'dart:async';

import 'package:flutter/material.dart';

import 'mock_scenario_definition.dart';
import 'mock_scenario_math.dart';
import 'mock_scenario_state.dart';

typedef MockScenarioCueFrame = FutureOr<void> Function(MockScenarioState state);
typedef MockScenarioStopCue = FutureOr<void> Function();
typedef MockScenarioScriptLine = FutureOr<void> Function(
    String scriptLineId, String fallbackMessage);
typedef MockScenarioStopScriptAudio = FutureOr<void> Function();

class MockScenarioController extends ChangeNotifier {
  MockScenarioController(
      {this.onCueFrame,
      this.onStopCue,
      this.onScriptLine,
      this.onStopScriptAudio})
      : _state = MockScenarioState.initial(
          scenario: mockScenarioDefinitions.first,
        ) {
    _state = _buildState(isPlaying: false);
  }

  static const Duration _tickInterval = Duration(milliseconds: 33);
  static const Duration _cueFrameInterval = Duration(milliseconds: 90);

  final MockScenarioCueFrame? onCueFrame;
  final MockScenarioStopCue? onStopCue;
  final MockScenarioScriptLine? onScriptLine;
  // 멈춤/처음부터/시나리오 전환 시 재생 중인 안내 음성을 끊어 이전 음성이 새 실행에
  // 겹치지 않게 한다.
  final MockScenarioStopScriptAudio? onStopScriptAudio;

  final List<MockScenarioDefinition> scenarios = mockScenarioDefinitions;

  MockScenarioDefinition _scenario = mockScenarioDefinitions.first;
  MockScenarioState _state;
  Timer? _timer;
  DateTime? _lastTickAt;
  Duration _elapsed = Duration.zero;
  Duration _lastCueFrameAt = Duration(milliseconds: -1000);
  String? _lastScriptLineId;
  double _playbackSpeed = 1.0;

  MockScenarioState get state => _state;
  MockScenarioDefinition get selectedScenario => _scenario;
  double get playbackSpeed => _playbackSpeed;

  void selectScenario(String scenarioId) {
    final next = scenarios.firstWhere(
      (scenario) => scenario.id == scenarioId,
      orElse: () => _scenario,
    );
    if (next.id == _scenario.id) return;
    _timer?.cancel();
    _timer = null;
    _scenario = next;
    _elapsed = Duration.zero;
    _lastTickAt = null;
    _lastScriptLineId = null;
    _lastCueFrameAt = Duration(milliseconds: -1000);
    _state = _buildState(isPlaying: false, shouldStopCue: true);
    notifyListeners();
    _emitStopCue();
    _emitStopScriptAudio();
  }

  void setPlaybackSpeed(double speed) {
    _playbackSpeed = speed.clamp(0.5, 2.0).toDouble();
    _state = _state.copyWith(playbackSpeed: _playbackSpeed);
    notifyListeners();
  }

  void play() {
    if (_timer != null) return;
    if (_elapsed >= _scenario.duration) {
      _elapsed = Duration.zero;
      _lastScriptLineId = null;
    }
    _lastTickAt = DateTime.now();
    _timer = Timer.periodic(_tickInterval, _handleTick);
    _state = _buildState(isPlaying: true);
    notifyListeners();
    _emitFrameSideEffects(forceCue: true);
  }

  void pause() {
    if (_timer == null) return;
    _timer?.cancel();
    _timer = null;
    _lastTickAt = null;
    _state = _buildState(isPlaying: false);
    notifyListeners();
    _emitStopCue();
    _emitStopScriptAudio();
  }

  void togglePlayPause() {
    if (_state.isPlaying) {
      pause();
    } else {
      play();
    }
  }

  void reset() {
    _timer?.cancel();
    _timer = null;
    _elapsed = Duration.zero;
    _lastTickAt = null;
    _lastScriptLineId = null;
    _lastCueFrameAt = Duration(milliseconds: -1000);
    _state = _buildState(isPlaying: false, shouldStopCue: true);
    notifyListeners();
    _emitStopCue();
    _emitStopScriptAudio();
  }

  void restart() {
    reset();
    play();
  }

  void nextScenario() {
    final currentIndex = scenarios.indexWhere(
      (scenario) => scenario.id == _scenario.id,
    );
    final nextIndex = (currentIndex + 1) % scenarios.length;
    selectScenario(scenarios[nextIndex].id);
  }

  void previousScenario() {
    final currentIndex = scenarios.indexWhere(
      (scenario) => scenario.id == _scenario.id,
    );
    final previousIndex =
        (currentIndex - 1 + scenarios.length) % scenarios.length;
    selectScenario(scenarios[previousIndex].id);
  }

  void _handleTick(Timer timer) {
    final now = DateTime.now();
    final previous = _lastTickAt ?? now;
    _lastTickAt = now;
    final delta = now.difference(previous);
    final scaledDelta = Duration(
      microseconds: (delta.inMicroseconds * _playbackSpeed).round(),
    );
    _elapsed += scaledDelta;

    final isComplete = _elapsed >= _scenario.duration;
    if (isComplete) {
      _elapsed = _scenario.duration;
      _timer?.cancel();
      _timer = null;
      _lastTickAt = null;
    }

    _state = _buildState(isPlaying: !isComplete, shouldStopCue: isComplete);
    notifyListeners();
    _emitFrameSideEffects(forceCue: isComplete);

    if (isComplete) {
      _emitStopCue();
    }
  }

  MockScenarioState _buildState({
    required bool isPlaying,
    bool shouldStopCue = false,
  }) {
    final frame = _interpolatedFrame(_elapsed);
    final metrics = MockScenarioMath.calculate(
      userPosition: frame.userPosition,
      busPosition: frame.targetBusPosition,
    );
    final isOutsideGeofence = MockScenarioMath.isOutsideGeofence(
      userPosition: frame.userPosition,
      stopPosition: frame.stopPosition,
      radius: frame.geofenceRadius,
    );
    final progress = _scenario.duration.inMilliseconds == 0
        ? 1.0
        : (_elapsed.inMilliseconds / _scenario.duration.inMilliseconds)
            .clamp(0.0, 1.0)
            .toDouble();

    return MockScenarioState(
      scenarioId: _scenario.id,
      scenarioTitle: _scenario.title,
      scenarioSummary: _scenario.summary,
      elapsed: _elapsed,
      totalDuration: _scenario.duration,
      progress: progress,
      playbackSpeed: _playbackSpeed,
      isPlaying: isPlaying,
      phase: frame.phase,
      userPosition: frame.userPosition,
      stopPosition: frame.stopPosition,
      targetBusPosition: frame.targetBusPosition,
      secondaryBusPosition: frame.secondaryBusPosition,
      targetBusLabel: frame.targetBusLabel,
      secondaryBusLabel: frame.secondaryBusLabel,
      busMoving: frame.busMoving,
      busStopped: frame.busStopped,
      geofenceArmed: frame.geofenceArmed,
      geofenceReleased: frame.geofenceReleased,
      geofenceRadius: frame.geofenceRadius,
      isUserOutsideGeofence: isOutsideGeofence,
      distanceMeters: metrics.distanceMeters,
      directionLabel: metrics.directionLabel,
      pan: metrics.pan,
      gain: metrics.gain,
      beepIntervalMs: metrics.beepIntervalMs,
      cueType: frame.cueType,
      shouldPlayCue: frame.cueType != 'none' && frame.cueType != 'success',
      shouldStopCue: shouldStopCue || frame.cueType == 'success',
      currentScriptLineId: frame.scriptLineId,
      currentScenarioMessage: frame.message,
    );
  }

  MockScenarioKeyframe _interpolatedFrame(Duration elapsed) {
    final frames = _scenario.keyframes;
    if (elapsed <= frames.first.at) return frames.first;
    if (elapsed >= frames.last.at) return frames.last;

    var previous = frames.first;
    var next = frames.last;
    for (var index = 0; index < frames.length - 1; index += 1) {
      final a = frames[index];
      final b = frames[index + 1];
      if (elapsed >= a.at && elapsed <= b.at) {
        previous = a;
        next = b;
        break;
      }
    }

    final segmentMs = next.at.inMilliseconds - previous.at.inMilliseconds;
    final localMs = elapsed.inMilliseconds - previous.at.inMilliseconds;
    final t = segmentMs <= 0 ? 1.0 : (localMs / segmentMs).clamp(0.0, 1.0);

    return MockScenarioKeyframe(
      at: elapsed,
      phase: previous.phase,
      userPosition: Offset.lerp(previous.userPosition, next.userPosition, t)!,
      stopPosition: Offset.lerp(previous.stopPosition, next.stopPosition, t)!,
      targetBusPosition: Offset.lerp(
        previous.targetBusPosition,
        next.targetBusPosition,
        t,
      )!,
      secondaryBusPosition: _lerpNullableOffset(
        previous.secondaryBusPosition,
        next.secondaryBusPosition,
        t,
      ),
      busMoving: previous.busMoving,
      busStopped: previous.busStopped,
      geofenceArmed: previous.geofenceArmed,
      geofenceReleased: previous.geofenceReleased,
      geofenceRadius: _lerpDouble(
        previous.geofenceRadius,
        next.geofenceRadius,
        t,
      ),
      cueType: previous.cueType,
      message: previous.message,
      targetBusLabel: previous.targetBusLabel,
      secondaryBusLabel: previous.secondaryBusLabel,
      scriptLineId: previous.scriptLineId,
    );
  }

  Offset? _lerpNullableOffset(Offset? a, Offset? b, double t) {
    if (a == null && b == null) return null;
    if (a == null) return t < 0.15 ? null : b;
    if (b == null) return t > 0.85 ? null : a;
    return Offset.lerp(a, b, t);
  }

  double _lerpDouble(double a, double b, double t) {
    return a + ((b - a) * t);
  }

  void _emitFrameSideEffects({bool forceCue = false}) {
    final scriptLineId = _state.currentScriptLineId;
    if (scriptLineId != null && scriptLineId != _lastScriptLineId) {
      _lastScriptLineId = scriptLineId;
      Future<void>.sync(
        () => onScriptLine?.call(scriptLineId, _state.currentScenarioMessage),
      );
    }

    if (_state.shouldStopCue) {
      _emitStopCue();
      return;
    }

    if (!_state.shouldPlayCue) return;
    final cueDue =
        forceCue || _state.elapsed - _lastCueFrameAt >= _cueFrameInterval;
    if (!cueDue) return;
    _lastCueFrameAt = _state.elapsed;
    Future<void>.sync(() => onCueFrame?.call(_state));
  }

  void _emitStopCue() {
    Future<void>.sync(() => onStopCue?.call());
  }

  void _emitStopScriptAudio() {
    Future<void>.sync(() => onStopScriptAudio?.call());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    _emitStopCue();
    super.dispose();
  }
}
