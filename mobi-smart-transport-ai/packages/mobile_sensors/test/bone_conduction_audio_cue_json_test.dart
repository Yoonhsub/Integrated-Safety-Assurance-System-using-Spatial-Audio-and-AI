import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_mobile_sensors/mobi_mobile_sensors.dart';

void main() {
  group('BoneConductionAudioCue JSON guard', () {
    final baseJson = <String, Object?>{
      'cueId': 'cue-section-json-guard',
      'beaconId': 'MOBI_STOP_BEACON_001',
      'message': '정류장 근처입니다. 탑승 위치를 확인하세요.',
      'signalLevel': 'CLOSE',
      'estimatedDistanceMeters': 2.4,
      'proximityTrend': 'APPROACHING',
      'sourceEventType': 'BEACON_NEAR',
      'urgency': 'MEDIUM',
      'repeatIntervalMs': 3000,
      'shouldRepeat': true,
      'createdAt': '2026-05-25T12:00:00.000Z',
    };

    BoneConductionAudioCue decodeCue(Map<String, Object?> overrides) {
      final json = <String, Object?>{...baseJson, ...overrides};
      final decoded = jsonDecode(jsonEncode(json)) as Map<String, dynamic>;
      return BoneConductionAudioCue.fromJson(
        Map<String, Object?>.from(decoded),
      );
    }

    test('decodes a valid jsonDecode payload', () {
      final cue = decodeCue({});

      expect(cue.cueId, 'cue-section-json-guard');
      expect(cue.beaconId, 'MOBI_STOP_BEACON_001');
      expect(cue.signalLevel, BeaconSignalLevel.close);
      expect(cue.proximityTrend, BeaconProximityTrend.approaching);
      expect(cue.sourceEventType, ProximityEventType.beaconNear);
      expect(cue.urgency, BoneConductionCueUrgency.medium);
      expect(cue.estimatedDistanceMeters, 2.4);
      expect(cue.repeatIntervalMs, 3000);
      expect(cue.shouldRepeat, isTrue);
      expect(cue.createdAt, DateTime.parse('2026-05-25T12:00:00.000Z'));
    });

    test('allows nullable enum/string conversion fields to stay null', () {
      final cue = decodeCue({'proximityTrend': null, 'sourceEventType': null});

      expect(cue.proximityTrend, isNull);
      expect(cue.sourceEventType, isNull);
    });

    test('decodes spatial pan and stereo gain fields', () {
      final cue = decodeCue({
        'gain': 0.8,
        'leftGain': 0.2,
        'rightGain': 0.8,
        'pan': 0.75,
        'relativeBearingDegrees': 67.5,
      });

      expect(cue.gain, 0.8);
      expect(cue.leftGain, 0.2);
      expect(cue.rightGain, 0.8);
      expect(cue.pan, 0.75);
      expect(cue.relativeBearingDegrees, 67.5);
      expect(cue.toJson()['pan'], 0.75);
    });

    test('rejects missing or empty required string fields', () {
      expect(() => decodeCue({'cueId': ''}), throwsA(isA<ArgumentError>()));
      expect(
        () => decodeCue({'beaconId': null}),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => decodeCue({
          'message': <String, Object?>{'text': 'near stop'},
        }),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects non-string proximityTrend values before enum conversion', () {
      expect(
        () => decodeCue({
          'proximityTrend': <String, Object?>{'value': 'APPROACHING'},
        }),
        throwsA(isA<ArgumentError>()),
      );
    });

    test(
      'rejects non-string sourceEventType values before enum conversion',
      () {
        expect(
          () => decodeCue({
            'sourceEventType': <String, Object?>{'value': 'BEACON_NEAR'},
          }),
          throwsA(isA<ArgumentError>()),
        );
      },
    );

    test('rejects unknown proximityTrend strings', () {
      expect(
        () => decodeCue({'proximityTrend': 'SIDEWAYS'}),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects unknown sourceEventType strings', () {
      expect(
        () => decodeCue({'sourceEventType': 'BUS_APPROACHING'}),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects malformed core enum/string fields', () {
      expect(
        () => decodeCue({'signalLevel': 10}),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => decodeCue({'urgency': false}),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects malformed numeric and boolean fields', () {
      expect(
        () => decodeCue({'estimatedDistanceMeters': '2.4'}),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => decodeCue({'repeatIntervalMs': '3000'}),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => decodeCue({'shouldRepeat': 'true'}),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => decodeCue({'gain': 1.2}),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => decodeCue({'pan': -1.5}),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => decodeCue({'relativeBearingDegrees': 181}),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects malformed timestamp fields', () {
      expect(
        () => decodeCue({'createdAt': 20260525}),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => decodeCue({'createdAt': 'not-a-timestamp'}),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
