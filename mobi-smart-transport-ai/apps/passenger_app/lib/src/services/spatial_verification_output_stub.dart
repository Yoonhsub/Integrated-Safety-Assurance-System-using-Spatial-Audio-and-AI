import 'spatial_verification_engine.dart';

class WebSpatialTestOutput implements SpatialTestOutput {
  @override
  Future<void> prepareFromGesture() async =>
      throw UnsupportedError('Web Audio required');
  @override
  Future<bool> play(String mode, String direction) async =>
      throw UnsupportedError('Web Audio required');
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
  @override
  Map<String, dynamic> snapshot() => {'phase': 'unsupported'};
}
