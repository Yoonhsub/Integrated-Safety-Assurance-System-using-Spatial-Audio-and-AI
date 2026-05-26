import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_mobile_sensors/mobi_mobile_sensors.dart';

void main() {
  group('RssiMovingAverageSmoother', () {
    test('keeps a continuous strong signal in NEAR zone', () {
      final smoother = RssiMovingAverageSmoother(windowSize: 5);
      const estimator = BeaconDistanceEstimator();

      for (final rssi in [-56, -55, -57, -56, -55]) {
        smoother.addSample(rssi);
      }

      expect(estimator.classifyZone(smoother.smoothedRssi), BeaconDistanceZone.near);
      expect(estimator.classify(smoother.smoothedRssi), isNot(BeaconSignalLevel.lost));
    });

    test('keeps a continuous weak signal in FAR zone', () {
      final smoother = RssiMovingAverageSmoother(windowSize: 5);
      const estimator = BeaconDistanceEstimator();

      for (final rssi in [-88, -90, -89, -91, -90]) {
        smoother.addSample(rssi);
      }

      expect(estimator.classifyZone(smoother.smoothedRssi), BeaconDistanceZone.far);
      expect(estimator.classify(smoother.smoothedRssi), BeaconSignalLevel.far);
    });

    test('bounds a sudden RSSI spike so one sample does not dominate guidance', () {
      final smoother = RssiMovingAverageSmoother(
        windowSize: 5,
        maxSingleSampleDelta: 10,
      );
      const estimator = BeaconDistanceEstimator();

      for (final rssi in [-70, -71, -70, -69]) {
        smoother.addSample(rssi);
      }
      final beforeSpikeZone = estimator.classifyZone(smoother.smoothedRssi);

      smoother.addSample(-40);
      final afterSpikeZone = estimator.classifyZone(smoother.smoothedRssi);

      expect(beforeSpikeZone, BeaconDistanceZone.medium);
      expect(afterSpikeZone, BeaconDistanceZone.medium);
      expect(smoother.samples.last, greaterThanOrEqualTo(-60));
      expect(smoother.samples.last, lessThanOrEqualTo(-59));
    });

    test('resets stale RSSI after repeated signal loss', () {
      final smoother = RssiMovingAverageSmoother(
        windowSize: 5,
        lostResetThreshold: 3,
      );
      const estimator = BeaconDistanceEstimator();

      smoother.addSample(-60);
      smoother.addSample(-61);

      smoother.recordSignalLost();
      smoother.recordSignalLost();
      smoother.recordSignalLost();

      expect(smoother.samples, isEmpty);
      expect(smoother.smoothedRssi, 0);
      expect(estimator.classify(smoother.smoothedRssi), BeaconSignalLevel.lost);
      expect(estimator.classifyZone(smoother.smoothedRssi), BeaconDistanceZone.unknown);
    });
  });
}
