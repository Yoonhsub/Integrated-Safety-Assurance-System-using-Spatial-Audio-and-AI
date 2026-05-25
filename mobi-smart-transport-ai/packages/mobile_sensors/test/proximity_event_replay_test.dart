import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_mobile_sensors/mobi_mobile_sensors.dart';

void main() {
  group('BeaconReplayFixture', () {
    test('parses the mock beacon sequence fixture', () {
      final fixture = _loadSection6Fixture();

      expect(fixture.name, 'section11_sensor_debug_mock_beacon_sequence');
      expect(fixture.frames, hasLength(5));
      expect(fixture.signals.first.beaconId, 'MOBI_STOP_BEACON_001');
      expect(fixture.frames.first.direction, isNotNull);
      expect(fixture.frames.last.signal.signalLevel, BeaconSignalLevel.lost);
    });

    test('replays proximity event transitions without live BLE hardware', () async {
      final fixture = _loadSection6Fixture();
      final runner = ProximityEventReplayRunner(fixture: fixture);

      final events = await runner.collectEvents();
      final eventTypes = events.map((event) => event.eventType).toList();

      expect(
        eventTypes,
        [
          ProximityEventType.beaconNear,
          ProximityEventType.approachingStop,
          ProximityEventType.beaconNear,
          ProximityEventType.approachingStop,
          ProximityEventType.leavingStop,
          ProximityEventType.beaconLost,
        ],
      );

      expect(events.first.beaconId, 'MOBI_STOP_BEACON_001');
      expect(events.first.direction, isNotNull);
      expect(events.last.eventType, ProximityEventType.beaconLost);
      expect(events.last.rssi, isNull);
      expect(events.last.metadata['distanceZone'], 'UNKNOWN');
    });

    test('honors targetBeaconId filtering during replay', () async {
      final fixture = _loadSection6Fixture();
      final runner = ProximityEventReplayRunner(fixture: fixture);

      final events = await runner.collectEvents(targetBeaconId: 'OTHER_BEACON');

      expect(events, isEmpty);
    });

    test('sample proximity events document replay output payloads', () {
      final sample = _loadSampleProximityEvents();
      final events = sample['events'] as List;

      expect(sample['sourceFixture'], 'packages/mobile_sensors/fixtures/mock_beacon_sequence.json');
      expect(events, hasLength(6));
      expect(events.first['eventType'], 'BEACON_NEAR');
      expect(events.last['eventType'], 'BEACON_LOST');
      expect(events.last['rssi'], isNull);
    });
  });
}

BeaconReplayFixture _loadSection6Fixture() {
  final candidates = [
    File('fixtures/mock_beacon_sequence.json'),
    File('packages/mobile_sensors/fixtures/mock_beacon_sequence.json'),
  ];

  final file = candidates.firstWhere(
    (candidate) => candidate.existsSync(),
    orElse: () => throw StateError('mock_beacon_sequence.json fixture not found.'),
  );
  final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  return BeaconReplayFixture.fromJson(Map<String, Object?>.from(json));
}

Map<String, Object?> _loadSampleProximityEvents() {
  final candidates = [
    File('fixtures/sample_proximity_events.json'),
    File('packages/mobile_sensors/fixtures/sample_proximity_events.json'),
  ];

  final file = candidates.firstWhere(
    (candidate) => candidate.existsSync(),
    orElse: () => throw StateError('sample_proximity_events.json fixture not found.'),
  );
  final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  return Map<String, Object?>.from(json);
}
