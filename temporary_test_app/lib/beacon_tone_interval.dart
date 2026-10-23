/// Signal-strength pacing for a demo, not a calibrated physical distance.
int beaconToneIntervalMs(int rssi) {
  final strength = ((rssi + 85) / 40).clamp(0.0, 1.0);
  return (1400 - strength * 1180).round();
}
