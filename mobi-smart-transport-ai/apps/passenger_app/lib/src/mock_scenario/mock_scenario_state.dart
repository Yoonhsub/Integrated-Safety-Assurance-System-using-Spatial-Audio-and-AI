import 'package:flutter/material.dart';

import 'mock_scenario_phase.dart';

class MockScenarioState {
  const MockScenarioState({
    required this.phase,
    required this.userPosition,
    required this.stopPosition,
    required this.targetBusPosition,
    this.wrongBusPosition,
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

  factory MockScenarioState.initial() {
    return const MockScenarioState(
      phase: MockScenarioPhase.init,
      userPosition: Offset(0.5, 0.75),
      stopPosition: Offset(0.5, 0.45),
      targetBusPosition: Offset(0.05, 0.35),
      wrongBusPosition: Offset(0.9, 0.35),
      busMoving: false,
      busStopped: false,
      geofenceArmed: false,
      geofenceReleased: false,
      geofenceRadius: 0.18,
      isUserOutsideGeofence: false,
      distanceMeters: 0,
      directionLabel: '중앙',
      pan: 0,
      gain: 0.15,
      beepIntervalMs: 2400,
      cueType: 'none',
      shouldPlayCue: false,
      shouldStopCue: false,
      currentScriptLineId: null,
      currentScenarioMessage: 'Mock 시나리오를 시작할 준비가 되었습니다.',
    );
  }

  final MockScenarioPhase phase;
  final Offset userPosition;
  final Offset stopPosition;
  final Offset targetBusPosition;
  final Offset? wrongBusPosition;

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

    MockScenarioState copyWith({
    MockScenarioPhase? phase,
    Offset? userPosition,
    Offset? stopPosition,
    Offset? targetBusPosition,
    Offset? wrongBusPosition,
    bool clearWrongBusPosition = false,
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
      phase: phase ?? this.phase,
      userPosition: userPosition ?? this.userPosition,
      stopPosition: stopPosition ?? this.stopPosition,
      targetBusPosition: targetBusPosition ?? this.targetBusPosition,
      wrongBusPosition: clearWrongBusPosition
          ? null
          : wrongBusPosition ?? this.wrongBusPosition,
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
}
