import 'passenger_sensor_adapter.dart';

/// Passenger App lifecycle 상태를 sensor package가 이해할 수 있는 값으로 정리한 enum이다.
///
/// 이 enum은 앱 lifecycle observer를 직접 등록하지 않는다. Passenger App이
/// `AppLifecycleState` 또는 라우팅 상태를 이 값으로 변환해 adapter/policy에 전달한다.
enum PassengerSensorLifecyclePhase {
  foreground,
  background,
  paused,
  resumed,
  restarted,
  disposed,
}

extension PassengerSensorLifecyclePhaseJson on PassengerSensorLifecyclePhase {
  String toJsonValue() {
    switch (this) {
      case PassengerSensorLifecyclePhase.foreground:
        return 'FOREGROUND';
      case PassengerSensorLifecyclePhase.background:
        return 'BACKGROUND';
      case PassengerSensorLifecyclePhase.paused:
        return 'PAUSED';
      case PassengerSensorLifecyclePhase.resumed:
        return 'RESUMED';
      case PassengerSensorLifecyclePhase.restarted:
        return 'RESTARTED';
      case PassengerSensorLifecyclePhase.disposed:
        return 'DISPOSED';
    }
  }
}

/// 권한/lifecycle 조합에서 Passenger App이 취할 수 있는 sensor 동작이다.
enum PassengerSensorLifecycleAction {
  startScan,
  keepScanning,
  stopScan,
  resumeScan,
  useMockReplay,
  showPermissionRationale,
  doNothing,
}

extension PassengerSensorLifecycleActionJson on PassengerSensorLifecycleAction {
  String toJsonValue() {
    switch (this) {
      case PassengerSensorLifecycleAction.startScan:
        return 'START_SCAN';
      case PassengerSensorLifecycleAction.keepScanning:
        return 'KEEP_SCANNING';
      case PassengerSensorLifecycleAction.stopScan:
        return 'STOP_SCAN';
      case PassengerSensorLifecycleAction.resumeScan:
        return 'RESUME_SCAN';
      case PassengerSensorLifecycleAction.useMockReplay:
        return 'USE_MOCK_REPLAY';
      case PassengerSensorLifecycleAction.showPermissionRationale:
        return 'SHOW_PERMISSION_RATIONALE';
      case PassengerSensorLifecycleAction.doNothing:
        return 'DO_NOTHING';
    }
  }
}

/// 권한 상태와 앱 lifecycle 상태를 함께 본 뒤 sensor 연결부가 사용할 결정값이다.
class PassengerSensorLifecycleDecision {
  const PassengerSensorLifecycleDecision({
    required this.action,
    required this.phase,
    required this.permissionStatus,
    required this.reason,
    this.shouldStartScan = false,
    this.shouldStopScan = false,
    this.shouldUseMockReplay = false,
    this.shouldShowPermissionUi = false,
  });

  final PassengerSensorLifecycleAction action;
  final PassengerSensorLifecyclePhase phase;
  final PassengerSensorPermissionStatus permissionStatus;
  final bool shouldStartScan;
  final bool shouldStopScan;
  final bool shouldUseMockReplay;
  final bool shouldShowPermissionUi;
  final String reason;

  Map<String, Object?> toJson() => {
        'action': action.toJsonValue(),
        'phase': phase.toJsonValue(),
        'permissionStatus': permissionStatus.toJsonValue(),
        'shouldStartScan': shouldStartScan,
        'shouldStopScan': shouldStopScan,
        'shouldUseMockReplay': shouldUseMockReplay,
        'shouldShowPermissionUi': shouldShowPermissionUi,
        'reason': reason,
      };
}

/// Passenger App이 BLE scan 시작/중지/재개를 일관되게 판단할 수 있게 하는 정책 helper이다.
///
/// 실제 권한 요청, Flutter lifecycle observer, background service 구현은 앱 담당이다.
/// 이 policy는 `PassengerSensorPermissionSnapshot`과 앱이 전달한 phase를 바탕으로
/// 어떤 동작을 선택해야 하는지 결정값만 제공한다.
class PassengerSensorLifecyclePolicy {
  const PassengerSensorLifecyclePolicy({
    this.stopScanWhenBackgrounded = true,
    this.allowMockReplayWhenPermissionBlocked = true,
  });

  /// background/paused 상태에서 BLE scan을 중지할지 여부이다.
  final bool stopScanWhenBackgrounded;

  /// 권한 없음/거부/기기 서비스 비활성화 상태에서 mock/replay fallback을 허용할지 여부이다.
  final bool allowMockReplayWhenPermissionBlocked;

  PassengerSensorLifecycleDecision decide({
    required PassengerSensorPermissionSnapshot permission,
    required PassengerSensorLifecyclePhase phase,
    bool wasScanning = false,
  }) {
    if (phase == PassengerSensorLifecyclePhase.disposed) {
      return PassengerSensorLifecycleDecision(
        action: PassengerSensorLifecycleAction.stopScan,
        phase: phase,
        permissionStatus: permission.status,
        shouldStopScan: true,
        reason: 'Adapter or screen is disposed. Cancel subscriptions and stop BLE scan.',
      );
    }

    if (phase == PassengerSensorLifecyclePhase.background ||
        phase == PassengerSensorLifecyclePhase.paused) {
      if (stopScanWhenBackgrounded && wasScanning) {
        return PassengerSensorLifecycleDecision(
          action: PassengerSensorLifecycleAction.stopScan,
          phase: phase,
          permissionStatus: permission.status,
          shouldStopScan: true,
          reason: 'App is not foreground. Stop scan to avoid stale sensor events and permission risk.',
        );
      }
      return PassengerSensorLifecycleDecision(
        action: PassengerSensorLifecycleAction.doNothing,
        phase: phase,
        permissionStatus: permission.status,
        reason: 'App is not foreground and scanner is already stopped.',
      );
    }

    if (!permission.canStartScan) {
      return _blockedByPermission(permission: permission, phase: phase);
    }

    if (phase == PassengerSensorLifecyclePhase.restarted ||
        phase == PassengerSensorLifecyclePhase.resumed) {
      return PassengerSensorLifecycleDecision(
        action: wasScanning
            ? PassengerSensorLifecycleAction.keepScanning
            : PassengerSensorLifecycleAction.resumeScan,
        phase: phase,
        permissionStatus: permission.status,
        shouldStartScan: !wasScanning,
        reason: wasScanning
            ? 'App resumed while scanner is already active. Keep current subscription.'
            : 'App resumed or restarted with ready permissions. Recreate subscription and resume scan.',
      );
    }

    return PassengerSensorLifecycleDecision(
      action: wasScanning
          ? PassengerSensorLifecycleAction.keepScanning
          : PassengerSensorLifecycleAction.startScan,
      phase: phase,
      permissionStatus: permission.status,
      shouldStartScan: !wasScanning,
      reason: wasScanning
          ? 'App is foreground and scanner is already active.'
          : 'App is foreground with ready permissions. Start BLE scan.',
    );
  }

  PassengerSensorLifecycleDecision _blockedByPermission({
    required PassengerSensorPermissionSnapshot permission,
    required PassengerSensorLifecyclePhase phase,
  }) {
    switch (permission.status) {
      case PassengerSensorPermissionStatus.bluetoothPermissionDenied:
      case PassengerSensorPermissionStatus.locationPermissionDenied:
        return PassengerSensorLifecycleDecision(
          action: PassengerSensorLifecycleAction.showPermissionRationale,
          phase: phase,
          permissionStatus: permission.status,
          shouldStopScan: true,
          shouldShowPermissionUi: true,
          shouldUseMockReplay: allowMockReplayWhenPermissionBlocked,
          reason: 'Required BLE or location permission is denied. Do not start live scan.',
        );
      case PassengerSensorPermissionStatus.bluetoothOff:
      case PassengerSensorPermissionStatus.locationOff:
      case PassengerSensorPermissionStatus.unavailable:
      case PassengerSensorPermissionStatus.unknown:
        return PassengerSensorLifecycleDecision(
          action: allowMockReplayWhenPermissionBlocked
              ? PassengerSensorLifecycleAction.useMockReplay
              : PassengerSensorLifecycleAction.doNothing,
          phase: phase,
          permissionStatus: permission.status,
          shouldStopScan: true,
          shouldUseMockReplay: allowMockReplayWhenPermissionBlocked,
          reason: 'Live sensor is not ready. Use mock/replay only if the app explicitly chooses fallback.',
        );
      case PassengerSensorPermissionStatus.ready:
        return PassengerSensorLifecycleDecision(
          action: PassengerSensorLifecycleAction.startScan,
          phase: phase,
          permissionStatus: permission.status,
          shouldStartScan: true,
          reason: 'Permissions are ready. Start BLE scan.',
        );
    }
  }
}
