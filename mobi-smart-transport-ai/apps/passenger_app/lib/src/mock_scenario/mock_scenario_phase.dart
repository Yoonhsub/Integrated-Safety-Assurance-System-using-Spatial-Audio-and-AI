enum MockScenarioPhase {
  init,
  atStopGeofenceArmed,
  busApproaching,
  busMovingLeftToRight,
  busStopped,
  userApproachingBus,
  boardingPrompt,
  boarded,
  missedBus,
  wrongBusWarning,
  geofenceWarning,
  dangerWarning,
  signalLost,
  routeChanged,
}

extension MockScenarioPhaseLabel on MockScenarioPhase {
  String get label {
    return switch (this) {
      MockScenarioPhase.init => '대기',
      MockScenarioPhase.atStopGeofenceArmed => '안전 구역 대기',
      MockScenarioPhase.busApproaching => '버스 접근',
      MockScenarioPhase.busMovingLeftToRight => '버스 이동',
      MockScenarioPhase.busStopped => '버스 정차',
      MockScenarioPhase.userApproachingBus => '탑승 위치 이동',
      MockScenarioPhase.boardingPrompt => '탑승 안내',
      MockScenarioPhase.boarded => '탑승 완료',
      MockScenarioPhase.missedBus => '버스 놓침',
      MockScenarioPhase.wrongBusWarning => '오탑승 경고',
      MockScenarioPhase.geofenceWarning => '지오펜스 경고',
      MockScenarioPhase.dangerWarning => '위험 구역 경고',
      MockScenarioPhase.signalLost => '비콘 신호 약화',
      MockScenarioPhase.routeChanged => '목표 변경',
    };
  }
}
