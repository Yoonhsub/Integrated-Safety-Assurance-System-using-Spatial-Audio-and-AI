import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:mobi_mobile_sensors/mobi_mobile_sensors.dart';

/// Public local demonstration data, never an authenticated vehicle registry.
/// Android remoteId is the existing scanner's device address, NOT advName.
class LocalDemoBeaconMapping {
  const LocalDemoBeaconMapping.disabled()
      : enabled = false,
        identities = const [],
        issue = null;
  const LocalDemoBeaconMapping._(this.enabled, this.identities, this.issue);
  final bool enabled;
  final List<BeaconIngestIdentity> identities;
  final String? issue;
  static LocalDemoBeaconMapping fromEnvironment() =>
      parse(const String.fromEnvironment('MOBI_BLE_LOCAL_DEMO_MAPPING'),
          allowed: kDebugMode);

  static LocalDemoBeaconMapping parse(String value, {required bool allowed}) {
    if (!allowed || value.isEmpty) {
      return const LocalDemoBeaconMapping.disabled();
    }
    try {
      final data = jsonDecode(value);
      if (data is! Map ||
          data.keys.toSet().difference(
              {'schemaVersion', 'identifierField', 'entries'}).isNotEmpty ||
          data['schemaVersion'] != 1 ||
          data['identifierField'] != 'android.remoteId' ||
          data['entries'] is! List ||
          (data['entries'] as List).length > 32) {
        throw const FormatException();
      }
      final entries = <BeaconIngestIdentity>[], used = <String>{};
      for (final row in data['entries'] as List) {
        if (row is! Map ||
            row.keys
                .toSet()
                .difference({'beaconId', 'busId', 'routeNo'}).isNotEmpty) {
          throw const FormatException();
        }
        final id = row['beaconId'], bus = row['busId'], route = row['routeNo'];
        if (id is! String ||
            bus is! String ||
            route is! String ||
            bus.trim().isEmpty ||
            route.trim().isEmpty ||
            bus.length > 128 ||
            route.length > 64) {
          throw const FormatException();
        }
        final address = BeaconIngestPayload.maybeNormalizeMacAddress(id);
        if (address == null || !used.add(address)) {
          throw const FormatException();
        }
        entries.add(BeaconIngestIdentity(
            beaconId: address, busId: bus.trim(), routeNo: route.trim()));
      }
      return LocalDemoBeaconMapping._(true, List.unmodifiable(entries), null);
    } catch (_) {
      return const LocalDemoBeaconMapping._(
          false, [], '로컬 시연 비콘 설정 오류 · 식별 비활성화');
    }
  }

  List<BeaconIngestIdentity> find(String remoteId) {
    final address = BeaconIngestPayload.maybeNormalizeMacAddress(remoteId);
    if (!enabled || address == null) return const [];
    return identities.where((row) => row.beaconId == address).toList();
  }
}
