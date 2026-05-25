import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_mobile_sensors/mobi_mobile_sensors.dart';

void main() {
  group('BeaconAudioCueFactory', () {
    const factory = BeaconAudioCueFactory();
    final baseTime = DateTime.parse('2026-05-25T12:00:00Z');

    test('creates a stable cue for a known BEACON_NEAR event', () {
      final event = _event(
        ProximityEventType.beaconNear,
        signalLevel: BeaconSignalLevel.close,
        timestamp: baseTime,
      );

      final cue = factory.createCueForEvent(event);

      expect(cue.sourceEventType, ProximityEventType.beaconNear);
      expect(cue.message, '정류장 근처입니다. 탑승 위치를 확인하세요.');
      expect(cue.urgency, BoneConductionCueUrgency.medium);
      expect(cue.repeatIntervalMs, 3000);
      expect(cue.shouldRepeat, isTrue);
    });

    test('creates a fallback cue for an unknown event name', () {
      final cue = factory.createFallbackCueForUnknownEvent(
        'BUS_APPROACHING',
        beaconId: 'MOBI_STOP_BEACON_001',
        createdAt: baseTime,
      );

      expect(cue.sourceEventType, isNull);
      expect(cue.message, '확인되지 않은 센서 이벤트입니다. 주변을 확인하세요.');
      expect(cue.urgency, BoneConductionCueUrgency.high);
      expect(cue.repeatIntervalMs, 2000);
      expect(cue.shouldRepeat, isTrue);
    });

    test('suppresses repeated non-critical cues inside the cooldown window', () {
      final first = factory.createCueForEvent(
        _event(
          ProximityEventType.beaconNear,
          timestamp: baseTime,
        ),
      );
      final repeated = factory.createCueForEvent(
        _event(
          ProximityEventType.beaconNear,
          timestamp: baseTime.add(const Duration(milliseconds: 700)),
        ),
      );
      final later = factory.createCueForEvent(
        _event(
          ProximityEventType.beaconNear,
          timestamp: baseTime.add(const Duration(seconds: 3)),
        ),
      );

      expect(factory.shouldSuppressRepeatedCue(first, repeated), isTrue);
      expect(factory.shouldSuppressRepeatedCue(first, later), isFalse);
    });

    test('does not suppress repeated critical lost cues', () {
      final first = factory.createCueForEvent(
        _event(
          ProximityEventType.beaconLost,
          signalLevel: BeaconSignalLevel.lost,
          rssi: null,
          timestamp: baseTime,
        ),
      );
      final repeated = factory.createCueForEvent(
        _event(
          ProximityEventType.beaconLost,
          signalLevel: BeaconSignalLevel.lost,
          rssi: null,
          timestamp: baseTime.add(const Duration(milliseconds: 500)),
        ),
      );

      expect(first.urgency, BoneConductionCueUrgency.critical);
      expect(factory.shouldSuppressRepeatedCue(first, repeated), isFalse);
    });

    test('selects the highest priority cue when events conflict', () {
      final nearCue = factory.createCueForEvent(
        _event(
          ProximityEventType.beaconNear,
          signalLevel: BeaconSignalLevel.close,
          timestamp: baseTime,
        ),
      );
      final leavingCue = factory.createCueForEvent(
        _event(
          ProximityEventType.leavingStop,
          signalLevel: BeaconSignalLevel.medium,
          timestamp: baseTime.add(const Duration(milliseconds: 100)),
        ),
      );
      final lostCue = factory.createCueForEvent(
        _event(
          ProximityEventType.beaconLost,
          signalLevel: BeaconSignalLevel.lost,
          rssi: null,
          timestamp: baseTime.add(const Duration(milliseconds: 200)),
        ),
      );

      final selected = factory.selectHighestPriorityCue([
        nearCue,
        leavingCue,
        lostCue,
      ]);

      expect(selected.sourceEventType, ProximityEventType.beaconLost);
      expect(selected.urgency, BoneConductionCueUrgency.critical);
    });

    test('can suppress repeated cues while converting an event stream', () async {
      final events = Stream<ProximityEvent>.fromIterable([
        _event(ProximityEventType.beaconNear, timestamp: baseTime),
        _event(
          ProximityEventType.beaconNear,
          timestamp: baseTime.add(const Duration(milliseconds: 400)),
        ),
        _event(
          ProximityEventType.leavingStop,
          signalLevel: BeaconSignalLevel.medium,
          timestamp: baseTime.add(const Duration(milliseconds: 800)),
        ),
      ]);

      final cues = await factory
          .createCueStreamFromEvents(events, suppressRepeatedEvents: true)
          .toList();

      expect(cues, hasLength(2));
      expect(cues.first.sourceEventType, ProximityEventType.beaconNear);
      expect(cues.last.sourceEventType, ProximityEventType.leavingStop);
    });
  });
}

ProximityEvent _event(
  ProximityEventType eventType, {
  BeaconSignalLevel signalLevel = BeaconSignalLevel.close,
  int? rssi = -64,
  DateTime? timestamp,
}) {
  return ProximityEvent(
    eventType: eventType,
    beaconId: 'MOBI_STOP_BEACON_001',
    rssi: rssi,
    estimatedDistanceMeters: signalLevel == BeaconSignalLevel.lost ? null : 2.4,
    signalLevel: signalLevel,
    timestamp: timestamp ?? DateTime.parse('2026-05-25T12:00:00Z'),
  );
}
