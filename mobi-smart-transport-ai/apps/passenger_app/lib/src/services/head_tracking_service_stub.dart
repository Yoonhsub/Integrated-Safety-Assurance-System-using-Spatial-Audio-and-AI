import '../models/v3_guidance_models.dart';

class HeadTrackingService {
  bool get supported => false;

  Future<HeadTrackingDebugSnapshot> connect() async {
    return const HeadTrackingDebugSnapshot(
      statusLabel: 'Web Bluetooth unavailable on this platform',
      isAvailable: false,
      sourceLabel: 'stub',
    );
  }

  HeadTrackingDebugSnapshot snapshot() {
    return HeadTrackingDebugSnapshot.disabled();
  }

  void resetZero() {}

  Future<void> disconnect() async {}
}
