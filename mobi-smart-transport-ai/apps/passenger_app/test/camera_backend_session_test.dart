import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobi_passenger_app/src/local_vision/camera_backend_session.dart';
import 'package:mobi_passenger_app/src/local_vision/frame_pump.dart';

Map<String, Object?> localConfig() => {
      'scope': 'local-camera-preview-v1',
      'baseUrl': 'http://127.0.0.1:8000',
      'passengerUid': 'passenger',
      'producerUid': 'producer',
      'cameraId': 'camera',
      'passengerToken': 'unit-only-passenger',
      'producerToken': 'unit-only-producer',
      'expiresAt': DateTime.now()
          .toUtc()
          .add(const Duration(minutes: 10))
          .toIso8601String()
    };
void main() {
  test(
      'local connection rejects admin fields, expired files and nonloopback URL',
      () {
    for (final value in [
      localConfig()..['adminToken'] = 'forbidden',
      localConfig()..['expiresAt'] = '2000-01-01T00:00:00Z'
    ]) {
      expect(
          () => CameraBackendConfig.parse(jsonEncode(value),
              baseUrl: 'http://127.0.0.1:8000'),
          throwsFormatException);
    }
    expect(
        () => CameraBackendConfig.parse(jsonEncode(localConfig()),
            baseUrl: 'http://192.168.0.2:8000'),
        throwsStateError);
  });
  test('unmarked host receives no credentials or Lease requests', () async {
    final calls = <http.Request>[];
    final session = CameraBackendSession(
        CameraBackendConfig.parse(jsonEncode(localConfig()),
            baseUrl: 'http://127.0.0.1:8000'), client: MockClient((r) async {
      calls.add(r);
      return http.Response('{}', 200);
    }));
    await expectLater(
        session.prepare(), throwsA(isA<VisionProducerException>()));
    expect(calls.length, 1);
    expect(calls.single.url.path, '/health');
    expect(calls.single.headers.containsKey('Authorization'), false);
    session.close();
  });
  test('binding cannot be chosen before a current Passenger session', () async {
    var calls = 0;
    final session = CameraBackendSession(
        CameraBackendConfig.parse(jsonEncode(localConfig()),
            baseUrl: 'http://127.0.0.1:8000'), client: MockClient((r) async {
      calls++;
      return http.Response('{}', 200);
    }));
    await expectLater(
        session.confirmBinding(), throwsA(isA<VisionProducerException>()));
    expect(calls, 0);
    session.close();
  });
  test('closed session sends no new HTTP and close is idempotent', () async {
    var calls = 0;
    final session = CameraBackendSession(
        CameraBackendConfig.parse(jsonEncode(localConfig()),
            baseUrl: 'http://127.0.0.1:8000'), client: MockClient((r) async {
      calls++;
      return http.Response('{}', 200);
    }));
    session.close();
    session.close();
    expect(session.isCurrent, false);
    await expectLater(
        session.prepare(), throwsA(isA<VisionProducerException>()));
    expect(calls, 0);
  });
}
