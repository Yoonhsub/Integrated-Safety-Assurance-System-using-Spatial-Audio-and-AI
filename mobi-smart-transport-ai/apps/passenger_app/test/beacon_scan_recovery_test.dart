import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_passenger_app/src/features/hardware_bus/continuous_beacon_scanner.dart';

void main() {
  test('stalled scan recovery has cooldown and never extends deadline', () {
    final guard = ScanRecoveryGuard();
    const end = Duration(minutes: 5);
    expect(guard.claim(const Duration(seconds: 1), Duration.zero, end), false);
    expect(guard.claim(const Duration(seconds: 2), Duration.zero, end), true);
    expect(guard.claim(const Duration(seconds: 3), Duration.zero, end), false);
    expect(
        guard.claim(
            const Duration(seconds: 32), const Duration(seconds: 31), end),
        false);
    expect(
        guard.claim(
            const Duration(seconds: 33), const Duration(seconds: 30), end),
        true);
    expect(
        guard.claim(const Duration(seconds: 299), Duration.zero, end), false);
  });
}
