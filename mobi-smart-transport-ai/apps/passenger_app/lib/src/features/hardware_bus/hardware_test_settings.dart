import 'dart:convert';
import 'package:mobi_mobile_sensors/mobi_mobile_sensors.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'concurrent_test_control.dart';

class HardwareTestSettings {
  static String? normalizeMac(String value) =>
      BeaconIngestPayload.maybeNormalizeMacAddress(value.trim());
}

class BusTestPairing {
  const BusTestPairing._(this.routeNo, this.mac);
  final String routeNo, mac;
  static BusTestPairing? parse(String route, String mac) {
    final target = TemporaryBusTarget.parse(route, mac);
    return target == null ? null : BusTestPairing._(target.routeNo, target.mac);
  }
}

abstract class HardwareTestSettingsStore {
  Future<BusTestPairing?> loadBus();
  Future<void> saveBus(BusTestPairing pairing);
  Future<void> resetBus();
  Future<String?> loadWit();
  Future<void> saveWit(String address);
  Future<void> resetWit();
}

/// Device-local demonstration identifiers only, never a verified vehicle registry.
class SharedPreferencesHardwareTestSettingsStore
    implements HardwareTestSettingsStore {
  static const busKey = 'hardware_test.bus_pairing.v1';
  static const witKey = 'hardware_test.wit_address.v1';
  Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();
  @override
  Future<BusTestPairing?> loadBus() async {
    final raw = (await _prefs).getString(busKey);
    if (raw == null) return null;
    final data = jsonDecode(raw);
    if (data is! Map || data['route'] is! String || data['mac'] is! String) {
      throw const FormatException('Invalid saved pairing');
    }
    final value =
        BusTestPairing.parse(data['route'] as String, data['mac'] as String);
    if (value == null) throw const FormatException('Invalid saved pairing');
    return value;
  }

  @override
  Future<void> saveBus(BusTestPairing pairing) async {
    final value = BusTestPairing.parse(pairing.routeNo, pairing.mac);
    if (value == null) throw const FormatException('Invalid pairing');
    // Both fields are written as one record; never a half-updated pairing.
    if (!await (await _prefs).setString(
        busKey, jsonEncode({'route': value.routeNo, 'mac': value.mac}))) {
      throw StateError('Local settings write failed');
    }
  }

  @override
  Future<void> resetBus() async {
    if (!await (await _prefs).remove(busKey)) {
      throw StateError('Local reset failed');
    }
  }

  @override
  Future<String?> loadWit() async {
    final raw = (await _prefs).getString(witKey);
    if (raw == null) return null;
    final value = HardwareTestSettings.normalizeMac(raw);
    if (value == null) {
      throw const FormatException('Invalid saved WT identifier');
    }
    return value;
  }

  @override
  Future<void> saveWit(String address) async {
    final value = HardwareTestSettings.normalizeMac(address);
    if (value == null) throw const FormatException('Invalid WT identifier');
    if (!await (await _prefs).setString(witKey, value)) {
      throw StateError('Local settings write failed');
    }
  }

  @override
  Future<void> resetWit() async {
    if (!await (await _prefs).remove(witKey)) {
      throw StateError('Local reset failed');
    }
  }
}
