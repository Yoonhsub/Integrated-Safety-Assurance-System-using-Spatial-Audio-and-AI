import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_passenger_app/src/features/hardware_bus/beacon_tone_interval.dart';

void main() {
  test(
    'stronger signals shorten the interval and weak signals lengthen it',
    () {
      expect(beaconToneIntervalMs(-45), 220);
      expect(beaconToneIntervalMs(-65), 810);
      expect(beaconToneIntervalMs(-85), 1400);
      expect(beaconToneIntervalMs(-30), 220);
      expect(beaconToneIntervalMs(-110), 1400);
      for (var rssi = -119; rssi <= 0; rssi++) {
        expect(
          beaconToneIntervalMs(rssi),
          lessThanOrEqualTo(beaconToneIntervalMs(rssi - 1)),
        );
        expect(beaconToneIntervalMs(rssi), inInclusiveRange(220, 1400));
      }
    },
  );
}
