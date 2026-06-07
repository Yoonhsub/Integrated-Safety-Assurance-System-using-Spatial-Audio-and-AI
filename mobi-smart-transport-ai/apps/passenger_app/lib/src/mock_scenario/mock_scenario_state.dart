import 'package:flutter/material.dart';

import 'mock_scenario_definition.dart';
import 'mock_scenario_phase.dart';

class MockScenarioState {
  const MockScenarioState({
    required this.scenarioId,
    required this.scenarioTitle,
    required this.scenarioSummary,
    required this.elapsed,
    required this.totalDuration,
    required this.progress,
    required this.playbackSpeed,
    required this.isPlaying,
    required this.phase,
    required this.userPosition,
    required this.stopPosition,
    required this.targetBusPosition,
    this.secondaryBusPosition,
    required this.targetBusLabel,
    this.secondaryBusLabel,
    required this.busMoving,
    required this.busStopped,
    required this.geofenceArmed,
    required this.geofenceReleased,
    required this.geofenceRadius,
    required this.isUserOutsideGeofence,
    required this.distanceMeters,
    required this.directionLabel,
    required this.pan,
    required this.gain,
    required this.beepIntervalMs,
    required this.cueType,
    required this.shouldPlayCue,
    required this.shouldStopCue,
    this.currentScriptLineId,
    required this.currentScenarioMessage,
  });

  factory MockScenarioState.initial({
    MockScenarioDefinition? scenario,
    double playbackSpeed = 1.0,
  }) {
    final selected = scenario ?? mockScenarioDefinitions.first;
    final first = selected.keyframes.first;
    return MockScenarioState(
      scenarioId: selected.id,
      scenarioTitle: selected.title,
      scenarioSummary: selected.summary,
      elapsed: Duration.zero,
      totalDuration: selected.duration,
      progress: 0,
      playbackSpeed: playbackSpeed,
      isPlaying: false,
      phase: first.phase,
      userPosition: first.userPosition,
      stopPosition: first.stopPosition,
      targetBusPosition: first.targetBusPosition,
      secondaryBusPosition: first.secondaryBusPosition,
      targetBusLabel: first.targetBusLabel,
      secondaryBusLabel: first.secondaryBusLabel,
      busMoving: first.busMoving,
      busStopped: first.busStopped,
      geofenceArmed: first.geofenceArmed,
      geofenceReleased: first.geofenceReleased,
      geofenceRadius: first.geofenceRadius,
      isUserOutsideGeofence: false,
      distanceMeters: 0,
      directionLabel: '중앙',
      pan: 0,
      gain: 0.15,
      beepIntervalMs: 2400,
      cueType: first.cueType,
      shouldPlayCue: false,
      shouldStopCue: false,
      currentScriptLineId: first.scriptLineId,
      currentScenarioMessage: first.message,
    );
  }

  final String scenarioId;
  final String scenarioTitle;
  final String scenarioSummary;
  final Duration elapsed;
  final Duration totalDuration;
  final double progress;
  final double playbackSpeed;
  final bool isPlaying;

  final MockScenarioPhase phase;
  final Offset userPosition;
  final Offset stopPosition;
  final Offset targetBusPosition;
  final Offset? secondaryBusPosition;
  final String targetBusLabel;
  final String? secondaryBusLabel;

  final bool busMoving;
  final bool busStopped;
  final bool geofenceArmed;
  final bool geofenceReleased;
  final double geofenceRadius;
  final bool isUserOutsideGeofence;

  final double distanceMeters;
  final String directionLabel;
  final double pan;
  final double gain;
  final int beepIntervalMs;

  final String cueType;
  final bool shouldPlayCue;
  final bool shouldStopCue;
  final String? currentScriptLineId;
  final String currentScenarioMessage;

  bool get isComplete => progress >= 1.0 && !isPlaying;

  String get elapsedLabel => _formatDuration(elapsed);
  String get totalDurationLabel => _formatDuration(totalDuration);

  MockScenarioState copyWith({
    String? scenarioId,
    String? scenarioTitle,
    String? scenarioSummary,
    Duration? elapsed,
    Duration? totalDuration,
    double? progress,
    double? playbackSpeed,
    bool? isPlaying,
    MockScenarioPhase? phase,
    Offset? userPosition,
    Offset? stopPosition,
    Offset? targetBusPosition,
    Offset? secondaryBusPosition,
    bool clearSecondaryBusPosition = false,
    String? targetBusLabel,
    String? secondaryBusLabel,
    bool clearSecondaryBusLabel = false,
    bool? busMoving,
    bool? busStopped,
    bool? geofenceArmed,
    bool? geofenceReleased,
    double? geofenceRadius,
    bool? isUserOutsideGeofence,
    double? distanceMeters,
    String? directionLabel,
    double? pan,
    double? gain,
    int? beepIntervalMs,
    String? cueType,
    bool? shouldPlayCue,
    bool? shouldStopCue,
    String? currentScriptLineId,
    bool clearCurrentScriptLineId = false,
    String? currentScenarioMessage,
  }) {
    return MockScenarioState(
      scenarioId: scenarioId ?? this.scenarioId,
      scenarioTitle: scenarioTitle ?? this.scenarioTitle,
      scenarioSummary: scenarioSummary ?? this.scenarioSummary,
      elapsed: elapsed ?? this.elapsed,
      totalDuration: totalDuration ?? this.totalDuration,
      progress: progress ?? this.progress,
      playbackSpeed: playbackSpeed ?? this.playbackSpeed,
      isPlaying: isPlaying ?? this.isPlaying,
      phase: phase ?? this.phase,
      userPosition: userPosition ?? this.userPosition,
      stopPosition: stopPosition ?? this.stopPosition,
      targetBusPosition: targetBusPosition ?? this.targetBusPosition,
      secondaryBusPosition: clearSecondaryBusPosition
          ? null
          : secondaryBusPosition ?? this.secondaryBusPosition,
      targetBusLabel: targetBusLabel ?? this.targetBusLabel,
      secondaryBusLabel: clearSecondaryBusLabel
          ? null
          : secondaryBusLabel ?? this.secondaryBusLabel,
      busMoving: busMoving ?? this.busMoving,
      busStopped: busStopped ?? this.busStopped,
      geofenceArmed: geofenceArmed ?? this.geofenceArmed,
      geofenceReleased: geofenceReleased ?? this.geofenceReleased,
      geofenceRadius: geofenceRadius ?? this.geofenceRadius,
      isUserOutsideGeofence:
          isUserOutsideGeofence ?? this.isUserOutsideGeofence,
      distanceMeters: distanceMeters ?? this.distanceMeters,
      directionLabel: directionLabel ?? this.directionLabel,
      pan: pan ?? this.pan,
      gain: gain ?? this.gain,
      beepIntervalMs: beepIntervalMs ?? this.beepIntervalMs,
      cueType: cueType ?? this.cueType,
      shouldPlayCue: shouldPlayCue ?? this.shouldPlayCue,
      shouldStopCue: shouldStopCue ?? this.shouldStopCue,
      currentScriptLineId: clearCurrentScriptLineId
          ? null
          : currentScriptLineId ?? this.currentScriptLineId,
      currentScenarioMessage:
          currentScenarioMessage ?? this.currentScenarioMessage,
    );
  }

  static String _formatDuration(Duration duration) {
    final seconds = duration.inSeconds;
    final minutes = seconds ~/ 60;
    final remain = seconds % 60;
    return '$minutes:${remain.toString().padLeft(2, '0')}';
  }
}
