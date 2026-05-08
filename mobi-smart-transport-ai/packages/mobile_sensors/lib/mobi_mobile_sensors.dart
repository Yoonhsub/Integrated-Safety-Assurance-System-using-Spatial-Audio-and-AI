/// Public API entrypoint for the MOBI mobile sensor package.
///
/// This package exposes BLE beacon signal models, RSSI distance estimation,
/// beacon scanner interfaces, and smartphone direction sensor interfaces.
/// It does not implement Flutter passenger/driver app UI.
library mobi_mobile_sensors;

export 'src/beacon_signal.dart';
export 'src/beacon_distance_estimator.dart';
export 'src/beacon_proximity_tracker.dart';
export 'src/beacon_scanner.dart';
export 'src/direction_sensor.dart';
export 'src/bone_conduction_audio_cue.dart';
