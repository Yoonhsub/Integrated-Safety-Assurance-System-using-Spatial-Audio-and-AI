import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_mobile_sensors/mobi_mobile_sensors.dart';

void main() {
  group('PassengerSensorLifecyclePolicy', () {
    const policy = PassengerSensorLifecyclePolicy();

    test('starts scan when app is foreground and permissions are ready', () {
      final decision = policy.decide(
        permission: PassengerSensorPermissionSnapshot.ready(
          checkedAt: DateTime.parse('2026-05-25T00:00:00Z'),
        ),
        phase: PassengerSensorLifecyclePhase.foreground,
      );

      expect(decision.action, PassengerSensorLifecycleAction.startScan);
      expect(decision.shouldStartScan, isTrue);
      expect(decision.shouldStopScan, isFalse);
    });

    test('stops scan when app goes background', () {
      final decision = policy.decide(
        permission: PassengerSensorPermissionSnapshot.ready(
          checkedAt: DateTime.parse('2026-05-25T00:00:00Z'),
        ),
        phase: PassengerSensorLifecyclePhase.background,
        wasScanning: true,
      );

      expect(decision.action, PassengerSensorLifecycleAction.stopScan);
      expect(decision.shouldStopScan, isTrue);
    });

    test('resumes scan after app restart when permissions are ready', () {
      final decision = policy.decide(
        permission: PassengerSensorPermissionSnapshot.ready(
          checkedAt: DateTime.parse('2026-05-25T00:00:00Z'),
        ),
        phase: PassengerSensorLifecyclePhase.restarted,
      );

      expect(decision.action, PassengerSensorLifecycleAction.resumeScan);
      expect(decision.shouldStartScan, isTrue);
    });

    test('does not start live scan when bluetooth permission is denied', () {
      final decision = policy.decide(
        permission: PassengerSensorPermissionSnapshot.fromStatus(
          status: PassengerSensorPermissionStatus.bluetoothPermissionDenied,
          checkedAt: DateTime.parse('2026-05-25T00:00:00Z'),
          bluetoothPermissionGranted: false,
        ),
        phase: PassengerSensorLifecyclePhase.foreground,
      );

      expect(
        decision.action,
        PassengerSensorLifecycleAction.showPermissionRationale,
      );
      expect(decision.shouldStartScan, isFalse);
      expect(decision.shouldStopScan, isTrue);
      expect(decision.shouldShowPermissionUi, isTrue);
    });

    test('uses mock replay fallback when sensor status is unknown', () {
      final decision = policy.decide(
        permission: PassengerSensorPermissionSnapshot.unknown(
          checkedAt: DateTime.parse('2026-05-25T00:00:00Z'),
        ),
        phase: PassengerSensorLifecyclePhase.foreground,
      );

      expect(decision.action, PassengerSensorLifecycleAction.useMockReplay);
      expect(decision.shouldUseMockReplay, isTrue);
      expect(decision.shouldStartScan, isFalse);
    });
  });
}
