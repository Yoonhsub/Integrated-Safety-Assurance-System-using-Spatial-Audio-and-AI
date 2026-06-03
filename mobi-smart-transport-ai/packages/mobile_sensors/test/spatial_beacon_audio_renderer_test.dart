import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_mobile_sensors/mobi_mobile_sensors.dart';

void main() {
  group('SpatialBeaconAudioRenderer', () {
    const renderer = SpatialBeaconAudioRenderer();
    final now = DateTime.parse('2026-06-04T00:00:00Z');

    test('maps closer distance to louder and faster beeps', () {
      final far = renderer.renderDoorGuidance(
        signal: _signal(rssi: -82, distanceMeters: 7.0, at: now),
      );
      final near = renderer.renderDoorGuidance(
        signal: _signal(rssi: -58, distanceMeters: 1.0, at: now),
      );

      expect(near.gain, greaterThan(far.gain));
      expect(near.beepIntervalMs, lessThan(far.beepIntervalMs));
    });

    test('maps relative bearing to left and right stereo gains', () {
      final center = renderer.renderDoorGuidance(
        signal: _signal(rssi: -64, distanceMeters: 2.0, at: now),
        direction: _direction(0, now),
        beaconBearingDegrees: 0,
      );
      final left = renderer.renderDoorGuidance(
        signal: _signal(rssi: -64, distanceMeters: 2.0, at: now),
        direction: _direction(0, now),
        beaconBearingDegrees: 270,
      );
      final right = renderer.renderDoorGuidance(
        signal: _signal(rssi: -64, distanceMeters: 2.0, at: now),
        direction: _direction(0, now),
        beaconBearingDegrees: 90,
      );

      expect(center.pan, 0);
      expect(center.leftGain, center.rightGain);
      expect(left.pan, lessThan(0));
      expect(left.leftGain, greaterThan(left.rightGain));
      expect(right.pan, greaterThan(0));
      expect(right.rightGain, greaterThan(right.leftGain));
    });

    test('creates arrival cue when distance is below threshold', () {
      final cue = renderer.createDoorGuidanceCue(
        signal: _signal(rssi: -52, distanceMeters: 0.3, at: now),
        createdAt: now,
      );

      expect(cue.shouldRepeat, isFalse);
      expect(cue.repeatIntervalMs, 0);
      expect(cue.message, '출입문에 도착했어, 탑승해');
    });

    test('creates critical danger cue with unsuppressed urgency', () {
      const factory = BeaconAudioCueFactory();
      final cue = factory.createDangerCue(
        _signal(
          beaconId: 'MOBI_DANGER_BEACON_001',
          rssi: -52,
          distanceMeters: 0.7,
          at: now,
        ),
        createdAt: now,
      );

      expect(cue.urgency, BoneConductionCueUrgency.critical);
      expect(cue.shouldRepeat, isTrue);
      expect(cue.repeatIntervalMs, 420);
      expect(cue.message, '위험구역이야, 물러나');
    });
  });

  group('BeaconDemoController', () {
    final now = DateTime.parse('2026-06-04T00:00:00Z');

    test('keeps danger active until release hysteresis is crossed', () {
      final controller = BeaconDemoController();
      final enter = controller.evaluateDangerSignal(
        _signal(
          beaconId: 'MOBI_DANGER_BEACON_001',
          rssi: -58,
          distanceMeters: 1.0,
          at: now,
        ),
        createdAt: now,
      );
      final stillActive = controller.evaluateDangerSignal(
        _signal(
          beaconId: 'MOBI_DANGER_BEACON_001',
          rssi: -68,
          distanceMeters: 2.0,
          at: now.add(const Duration(milliseconds: 500)),
        ),
        createdAt: now.add(const Duration(milliseconds: 500)),
      );
      final cleared = controller.evaluateDangerSignal(
        _signal(
          beaconId: 'MOBI_DANGER_BEACON_001',
          rssi: -82,
          distanceMeters: 3.2,
          at: now.add(const Duration(seconds: 1)),
        ),
        createdAt: now.add(const Duration(seconds: 1)),
      );

      expect(enter.isDangerActive, isTrue);
      expect(stillActive.isDangerActive, isTrue);
      expect(cleared.status, BeaconDemoStatus.dangerCleared);
      expect(cleared.dangerActive, isFalse);
    });
  });

  group('BeaconRssiCalibration', () {
    test('builds an estimator from measured 1m/2m/3m samples', () {
      final calibration = BeaconRssiCalibration.fromSamples(const [
        BeaconRssiCalibrationSample(distanceMeters: 1, rssi: -59),
        BeaconRssiCalibrationSample(distanceMeters: 2, rssi: -65),
        BeaconRssiCalibrationSample(distanceMeters: 3, rssi: -70),
      ]);
      final estimator = calibration.toEstimator();
      final estimate = estimator.estimate(-65);

      expect(calibration.txPower, closeTo(-59, 1));
      expect(calibration.pathLossExponent, inInclusiveRange(1.2, 4.5));
      expect(estimate.estimatedDistanceMeters, isNotNull);
    });
  });
}

BeaconSignal _signal({
  String beaconId = 'MOBI_DOOR_BEACON_001',
  required int rssi,
  required double distanceMeters,
  required DateTime at,
}) {
  return BeaconSignal(
    beaconId: beaconId,
    rssi: rssi,
    estimatedDistanceMeters: distanceMeters,
    signalLevel: const BeaconDistanceEstimator().classify(rssi),
    lastDetectedAt: at,
  );
}

DirectionReading _direction(double heading, DateTime at) {
  return DirectionReading(
    headingDegrees: heading,
    accuracy: DirectionAccuracy.high,
    updatedAt: at,
  );
}
