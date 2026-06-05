import 'package:flutter/material.dart';

import 'mock_scenario_math.dart';
import 'mock_scenario_phase.dart';
import 'mock_scenario_state.dart';

class MockScenarioController extends ChangeNotifier {
  MockScenarioState _state = MockScenarioState.initial();

  MockScenarioState get state => _state;

  void reset() {
    _state = MockScenarioState.initial();
    notifyListeners();
  }

  void arriveAtStop() {
    _state = _state.copyWith(
      phase: MockScenarioPhase.atStopGeofenceArmed,
      userPosition: _state.stopPosition,
      geofenceArmed: true,
      geofenceReleased: false,
      isUserOutsideGeofence: false,
      cueType: 'normal',
      shouldPlayCue: true,
      shouldStopCue: false,
      currentScriptLineId: 'arrive_at_stop',
      currentScenarioMessage: '정류장 안전 구역에 도착했습니다.',
    );

    _refreshMetrics();
  }

  void startTargetBusApproach() {
    _state = _state.copyWith(
      phase: MockScenarioPhase.busApproaching,
      targetBusPosition: const Offset(0.18, 0.35),
      busMoving: true,
      busStopped: false,
      cueType: 'normal',
      shouldPlayCue: true,
      shouldStopCue: false,
      currentScriptLineId: 'target_bus_approaching',
      currentScenarioMessage: '탑승 대상 버스가 왼쪽 방향에서 접근 중입니다.',
    );

    _refreshMetrics();
  }

  void moveBusLeftToRight() {
    _state = _state.copyWith(
      phase: MockScenarioPhase.busMovingLeftToRight,
      targetBusPosition: const Offset(0.72, 0.35),
      busMoving: true,
      busStopped: false,
      cueType: 'normal',
      shouldPlayCue: true,
      shouldStopCue: false,
      currentScriptLineId: 'target_bus_moving',
      currentScenarioMessage: '탑승 대상 버스가 왼쪽에서 오른쪽으로 이동 중입니다.',
    );

    _refreshMetrics();
  }

  void stopBus() {
    _state = _state.copyWith(
      phase: MockScenarioPhase.busStopped,
      targetBusPosition: const Offset(0.62, 0.45),
      busMoving: false,
      busStopped: true,
      geofenceReleased: true,
      cueType: 'normal',
      shouldPlayCue: true,
      shouldStopCue: false,
      currentScriptLineId: 'bus_stopped',
      currentScenarioMessage: '버스가 정차했습니다. 출입문 방향 안내를 시작합니다.',
    );

    _refreshMetrics();
  }

  void userApproachesBus() {
    _state = _state.copyWith(
      phase: MockScenarioPhase.userApproachingBus,
      userPosition: const Offset(0.58, 0.55),
      cueType: 'normal',
      shouldPlayCue: true,
      shouldStopCue: false,
      currentScriptLineId: 'user_approaching_bus',
      currentScenarioMessage: '사용자가 버스 출입문 방향으로 접근하고 있습니다.',
    );

    _refreshMetrics();
  }

  void showBoardingPrompt() {
    _state = _state.copyWith(
      phase: MockScenarioPhase.boardingPrompt,
      userPosition: const Offset(0.61, 0.50),
      cueType: 'normal',
      shouldPlayCue: true,
      shouldStopCue: false,
      currentScriptLineId: 'boarding_prompt',
      currentScenarioMessage: '출입문 근처입니다. 안전하게 탑승하세요.',
    );

    _refreshMetrics();
  }

  void confirmBoarded() {
    _state = _state.copyWith(
      phase: MockScenarioPhase.boarded,
      userPosition: _state.targetBusPosition,
      busMoving: false,
      busStopped: true,
      cueType: 'success',
      shouldPlayCue: false,
      shouldStopCue: true,
      currentScriptLineId: 'boarding_success',
      currentScenarioMessage: '탑승이 완료되었습니다.',
    );

    _refreshMetrics();
  }

    void userLeavesGeofence() {
    _state = _state.copyWith(
      phase: MockScenarioPhase.geofenceWarning,
      userPosition: const Offset(0.86, 0.82),
      geofenceArmed: true,
      geofenceReleased: false,
      isUserOutsideGeofence: true,
      cueType: 'alarm',
      shouldPlayCue: true,
      shouldStopCue: false,
      currentScriptLineId: 'geofence_warning',
      currentScenarioMessage: '정류장 안전 구역을 벗어났습니다. 안내음 방향을 따라 복귀하세요.',
    );

    _refreshMetrics();
  }

  void userReturnsToGeofence() {
    _state = _state.copyWith(
      phase: MockScenarioPhase.atStopGeofenceArmed,
      userPosition: _state.stopPosition,
      geofenceArmed: true,
      geofenceReleased: false,
      isUserOutsideGeofence: false,
      cueType: 'normal',
      shouldPlayCue: true,
      shouldStopCue: false,
      currentScriptLineId: 'return_to_geofence',
      currentScenarioMessage: '정류장 안전 구역 안으로 복귀했습니다.',
    );

    _refreshMetrics();
  }

  void wrongBusApproaches() {
    _state = _state.copyWith(
      phase: MockScenarioPhase.wrongBusWarning,
      wrongBusPosition: const Offset(0.78, 0.35),
      cueType: 'warning',
      shouldPlayCue: true,
      shouldStopCue: false,
      currentScriptLineId: 'wrong_bus_warning',
      currentScenarioMessage: '탑승 대상이 아닌 버스가 접근 중입니다. 현재 안내 대상 버스가 아닙니다.',
    );

    _refreshMetrics();
  }

  void confirmMissedBus() {
    _state = _state.copyWith(
      phase: MockScenarioPhase.missedBus,
      targetBusPosition: const Offset(0.95, 0.30),
      busMoving: true,
      busStopped: false,
      geofenceReleased: false,
      cueType: 'missed',
      shouldPlayCue: true,
      shouldStopCue: false,
      currentScriptLineId: 'missed_bus',
      currentScenarioMessage: '탑승 대상 버스를 놓쳤습니다. 다음 버스 안내를 기다려주세요.',
    );

    _refreshMetrics();
  }

  void _refreshMetrics() {
    final metrics = MockScenarioMath.calculate(
      userPosition: _state.userPosition,
      busPosition: _state.targetBusPosition,
    );

    final isOutsideGeofence = MockScenarioMath.isOutsideGeofence(
      userPosition: _state.userPosition,
      stopPosition: _state.stopPosition,
      radius: _state.geofenceRadius,
    );

    _state = _state.copyWith(
      distanceMeters: metrics.distanceMeters,
      directionLabel: metrics.directionLabel,
      pan: metrics.pan,
      gain: metrics.gain,
      beepIntervalMs: metrics.beepIntervalMs,
      isUserOutsideGeofence: isOutsideGeofence,
    );

    notifyListeners();
  }
}

