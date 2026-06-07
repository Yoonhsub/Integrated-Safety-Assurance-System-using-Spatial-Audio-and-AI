import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'beacon_scanner.dart';
import 'beacon_signal.dart';

typedef BeaconIngestIdentityResolver = BeaconIngestIdentity Function(
  BeaconSignal signal,
);

class BeaconIngestIdentity {
  const BeaconIngestIdentity({
    required this.beaconId,
    this.macAddress,
    this.busId,
    this.routeNo,
  }) : assert(beaconId.length > 0, 'beaconId must not be empty');

  final String beaconId;
  final String? macAddress;
  final String? busId;
  final String? routeNo;

  factory BeaconIngestIdentity.fromSignal(BeaconSignal signal) {
    return BeaconIngestIdentity(
      beaconId: signal.beaconId,
      macAddress: BeaconIngestPayload.maybeNormalizeMacAddress(signal.beaconId),
    );
  }
}

class BeaconIngestPayload {
  const BeaconIngestPayload({
    required this.sessionId,
    required this.deviceId,
    required this.beaconId,
    required this.rssi,
    required this.source,
    required this.timestamp,
    this.macAddress,
    this.busId,
    this.routeNo,
    this.distanceMeters,
  })  : assert(sessionId.length > 0, 'sessionId must not be empty'),
        assert(deviceId.length > 0, 'deviceId must not be empty'),
        assert(beaconId.length > 0, 'beaconId must not be empty'),
        assert(rssi >= -120 && rssi <= 0, 'rssi must be between -120 and 0'),
        assert(source.length > 0, 'source must not be empty'),
        assert(
          distanceMeters == null || distanceMeters >= 0,
          'distanceMeters must be non-negative or null',
        );

  final String sessionId;
  final String deviceId;
  final String beaconId;
  final String? macAddress;
  final String? busId;
  final String? routeNo;
  final int rssi;
  final double? distanceMeters;
  final String source;
  final DateTime timestamp;

  factory BeaconIngestPayload.fromSignal({
    required BeaconSignal signal,
    required String sessionId,
    required String deviceId,
    String source = 'REAL_BLE',
    BeaconIngestIdentityResolver? identityResolver,
  }) {
    final identity = identityResolver?.call(signal) ??
        BeaconIngestIdentity.fromSignal(signal);
    return BeaconIngestPayload(
      sessionId: sessionId,
      deviceId: deviceId,
      beaconId: identity.beaconId,
      macAddress: maybeNormalizeMacAddress(identity.macAddress),
      busId: _blankToNull(identity.busId),
      routeNo: _blankToNull(identity.routeNo),
      rssi: signal.rssi,
      distanceMeters: signal.estimatedDistanceMeters,
      source: source,
      timestamp: signal.lastDetectedAt,
    );
  }

  Map<String, Object?> toJson() {
    final json = <String, Object?>{
      'sessionId': sessionId,
      'deviceId': deviceId,
      'beaconId': beaconId,
      'macAddress': macAddress,
      'busId': busId,
      'routeNo': routeNo,
      'rssi': rssi,
      'distanceMeters': distanceMeters,
      'source': source,
      'timestamp': timestamp.toIso8601String(),
    };
    json.removeWhere((_, value) => value == null);
    return json;
  }

  static String? maybeNormalizeMacAddress(String? value) {
    final normalized = _blankToNull(value)?.replaceAll('-', ':').toUpperCase();
    if (normalized == null) return null;
    final pattern = RegExp(r'^[0-9A-F]{2}(:[0-9A-F]{2}){5}$');
    return pattern.hasMatch(normalized) ? normalized : null;
  }

  static String? _blankToNull(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    return trimmed;
  }
}

class BeaconIngestResult {
  const BeaconIngestResult({
    required this.statusCode,
    required this.body,
  });

  final int statusCode;
  final Map<String, Object?> body;
}

class BeaconIngestException implements Exception {
  const BeaconIngestException(this.message, {this.statusCode, this.body});

  final String message;
  final int? statusCode;
  final String? body;

  @override
  String toString() {
    if (statusCode == null) return 'BeaconIngestException: $message';
    return 'BeaconIngestException($statusCode): $message';
  }
}

class BeaconIngestClient {
  BeaconIngestClient({
    required Uri baseUri,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 5),
  })  : endpoint = baseUri.resolve('/api/v3/beacon/ingest'),
        _client = httpClient ?? http.Client(),
        _ownsClient = httpClient == null;

  final Uri endpoint;
  final Duration timeout;
  final http.Client _client;
  final bool _ownsClient;

  Future<BeaconIngestResult> send(BeaconIngestPayload payload) async {
    final response = await _client
        .post(
          endpoint,
          headers: const {'content-type': 'application/json'},
          body: jsonEncode(payload.toJson()),
        )
        .timeout(timeout);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw BeaconIngestException(
        'Beacon ingest request failed.',
        statusCode: response.statusCode,
        body: response.body,
      );
    }

    return BeaconIngestResult(
      statusCode: response.statusCode,
      body: _decodeJsonObject(response.body),
    );
  }

  void close() {
    if (_ownsClient) {
      _client.close();
    }
  }

  static Map<String, Object?> _decodeJsonObject(String body) {
    if (body.trim().isEmpty) return const <String, Object?>{};
    final decoded = jsonDecode(body);
    if (decoded is Map) {
      return Map<String, Object?>.from(decoded);
    }
    throw const BeaconIngestException(
        'Beacon ingest response was not a JSON object.');
  }
}

class BeaconIngestBridge {
  const BeaconIngestBridge({
    required this.scanner,
    required this.client,
    required this.sessionId,
    required this.deviceId,
    this.source = 'REAL_BLE',
    this.identityResolver,
    this.targetBeaconId,
  })  : assert(sessionId.length > 0, 'sessionId must not be empty'),
        assert(deviceId.length > 0, 'deviceId must not be empty'),
        assert(source.length > 0, 'source must not be empty');

  final BeaconScanner scanner;
  final BeaconIngestClient client;
  final String sessionId;
  final String deviceId;
  final String source;
  final BeaconIngestIdentityResolver? identityResolver;
  final String? targetBeaconId;

  Stream<BeaconIngestResult> sendScan({int? maxEvents}) async* {
    var sent = 0;

    await for (final signal in scanner.scan(targetBeaconId: targetBeaconId)) {
      final payload = BeaconIngestPayload.fromSignal(
        signal: signal,
        sessionId: sessionId,
        deviceId: deviceId,
        source: source,
        identityResolver: identityResolver,
      );
      yield await client.send(payload);

      sent += 1;
      if (maxEvents != null && sent >= maxEvents) {
        break;
      }
    }
  }

  Future<List<BeaconIngestResult>> collectAndSend({int? maxEvents}) async {
    final results = <BeaconIngestResult>[];
    await for (final result in sendScan(maxEvents: maxEvents)) {
      results.add(result);
    }
    return results;
  }

  Future<void> stop() => scanner.stop();
}
