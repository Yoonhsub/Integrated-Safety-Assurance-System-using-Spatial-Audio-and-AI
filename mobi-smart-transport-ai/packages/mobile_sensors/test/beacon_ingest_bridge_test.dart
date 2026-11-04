import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobi_mobile_sensors/mobi_mobile_sensors.dart';

void main() {
  group('BeaconIngestPayload', () {
    test('serializes local scan timestamps as UTC without changing the instant', () {
      final observedAt = DateTime(2026, 10, 23, 12, 34, 56, 123, 456);
      final signal = BeaconSignal(
        beaconId: targetMac,
        rssi: -55,
        estimatedDistanceMeters: 2.0,
        signalLevel: BeaconSignalLevel.close,
        lastDetectedAt: observedAt,
      );
      final payload = BeaconIngestPayload.fromSignal(
        signal: signal,
        sessionId: 'demo-session',
        deviceId: 'android-collector-01',
      );

      final timestamp = payload.toJson()['timestamp'] as String;
      expect(observedAt.isUtc, isFalse);
      expect(timestamp, endsWith('Z'));
      expect(timestamp, observedAt.toUtc().toIso8601String());
      expect(DateTime.parse(timestamp).isAtSameMomentAs(observedAt), isTrue);
      expect(payload.timestamp, observedAt);
    });

    test('normalizes MAC-like beacon ids for backend ingest', () {
      final signal = BeaconSignal(
        beaconId: 'c3-00-00-5c-b9-47',
        rssi: -55,
        estimatedDistanceMeters: 2.0,
        signalLevel: BeaconSignalLevel.veryClose,
        lastDetectedAt: DateTime.utc(2026, 6, 7, 0, 0),
      );

      final payload = BeaconIngestPayload.fromSignal(
        signal: signal,
        sessionId: 'demo-session',
        deviceId: 'android-collector-01',
      );

      expect(payload.toJson()['beaconId'], 'c3-00-00-5c-b9-47');
      expect(payload.toJson()['macAddress'], 'C3:00:00:5C:B9:47');
      expect(payload.toJson()['source'], 'REAL_BLE');
      expect(payload.toJson()['distanceMeters'], 2.0);
      expect(payload.toJson()['timestamp'], '2026-06-07T00:00:00.000Z');
    });
  });

  group('BeaconIngestBridge', () {
    test('posts scanner signals to /api/v3/beacon/ingest', () async {
      final capturedPayloads = <Map<String, Object?>>[];
      final httpClient = MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/api/v3/beacon/ingest');
        capturedPayloads.add(
          Map<String, Object?>.from(jsonDecode(request.body) as Map),
        );
        final timestamp = capturedPayloads.last['timestamp'] as String;
        expect(timestamp, endsWith('Z'));
        expect(
          DateTime.parse(timestamp).isAtSameMomentAs(
            DateTime(2026, 6, 7, 0, 0),
          ),
          isTrue,
        );
        return http.Response(
          jsonEncode(<String, Object?>{
            'sessionId': 'demo-session',
            'decision': capturedPayloads.last['macAddress'] == targetMac
                ? 'TARGET_BUS_NEAR'
                : 'WRONG_BUS_NEAR',
          }),
          200,
          headers: const {'content-type': 'application/json'},
        );
      });

      final scanner = MockBeaconScanner([
        _signal(targetMac, -55),
        _signal(wrongMac, -58),
      ]);
      final client = BeaconIngestClient(
        baseUri: Uri.parse('http://127.0.0.1:8000'),
        httpClient: httpClient,
      );
      final bridge = BeaconIngestBridge(
        scanner: scanner,
        client: client,
        sessionId: 'demo-session',
        deviceId: 'android-collector-01',
        identityResolver: (signal) => BeaconIngestIdentity(
          beaconId: 'same-uuid-major-minor',
          macAddress: signal.beaconId,
          routeNo: '502',
          busId:
              signal.beaconId == targetMac ? 'BUS_502_TARGET' : 'BUS_502_OTHER',
        ),
      );

      final results = await bridge.collectAndSend(maxEvents: 2);

      expect(results, hasLength(2));
      expect(capturedPayloads, hasLength(2));
      expect(capturedPayloads.first['macAddress'], targetMac);
      expect(capturedPayloads.first['beaconId'], 'same-uuid-major-minor');
      expect(capturedPayloads.first['busId'], 'BUS_502_TARGET');
      expect(capturedPayloads.first['routeNo'], '502');
      expect(capturedPayloads.last['macAddress'], wrongMac);
      expect(capturedPayloads.last['busId'], 'BUS_502_OTHER');
      expect(scanner.isScanning, isFalse);
    });
  });

  group('real beacon A/B fixture', () {
    test('documents target and wrong ingest samples', () {
      final fixture = _loadRealBeaconAbFixture();
      final samples = fixture['ingestSamples'] as List;

      expect(fixture['backendEndpoint'], '/api/v3/beacon/ingest');
      expect(samples, hasLength(2));
      expect(samples.first['macAddress'], targetMac);
      expect(samples.first['source'], 'REAL_BLE');
      expect(samples.last['macAddress'], wrongMac);
      expect(samples.last['source'], 'REAL_BLE');
    });
  });
}

const targetMac = 'C3:00:00:5C:B9:47';
const wrongMac = 'C3:00:00:5C:B9:48';

BeaconSignal _signal(String beaconId, int rssi) {
  return BeaconSignal(
    beaconId: beaconId,
    rssi: rssi,
    estimatedDistanceMeters: 2.0,
    signalLevel: BeaconSignalLevel.close,
    lastDetectedAt: DateTime(2026, 6, 7, 0, 0),
  );
}

Map<String, Object?> _loadRealBeaconAbFixture() {
  final candidates = [
    File('fixtures/real_beacon_ab_ingest_samples.json'),
    File('packages/mobile_sensors/fixtures/real_beacon_ab_ingest_samples.json'),
  ];

  final file = candidates.firstWhere(
    (candidate) => candidate.existsSync(),
    orElse: () =>
        throw StateError('real_beacon_ab_ingest_samples.json not found.'),
  );
  final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  return Map<String, Object?>.from(json);
}
