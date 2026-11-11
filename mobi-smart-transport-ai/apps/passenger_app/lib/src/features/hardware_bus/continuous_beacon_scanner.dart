import 'dart:async';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:mobi_mobile_sensors/mobi_mobile_sensors.dart';

/// Private diagnostic adapter. The original project's scanner is unchanged.
class ContinuousBeaconScanner implements BeaconScanner {
  ContinuousBeaconScanner({
    required this.beaconIdResolver,
    this.scanTimeout = const Duration(seconds: 15),
    Stream<BluetoothAdapterState>? adapterStates,
    Stream<List<ScanResult>>? scanResults,
    Future<void> Function()? startScan,
    Future<void> Function()? stopScan,
  })  : _adapterStates = adapterStates,
        _scanResults = scanResults,
        _startScan = startScan,
        _stopScan = stopScan;
  final Duration scanTimeout;
  final Stream<BluetoothAdapterState>? _adapterStates;
  final Stream<List<ScanResult>>? _scanResults;
  final Future<void> Function()? _startScan, _stopScan;

  final BeaconIdResolver beaconIdResolver;
  final _estimator = const BeaconDistanceEstimator();
  final Map<String, RssiMovingAverageSmoother> _smoothers = {};
  StreamController<BeaconSignal>? _controller;
  StreamSubscription<List<ScanResult>>? _results;
  StreamSubscription<BluetoothAdapterState>? _adapter;
  Timer? _timer;
  Future<void>? _stopTask;
  bool _scanning = false;

  @override
  bool get isScanning => _scanning;

  @override
  Stream<BeaconSignal> scan({String? targetBeaconId}) {
    if (_controller != null || _stopTask != null) {
      throw StateError('Create a new diagnostic scanner for each scan.');
    }
    final controller = StreamController<BeaconSignal>();
    _controller = controller;
    controller.onListen = () => unawaited(_start(controller, targetBeaconId));
    controller.onCancel = stop;
    return controller.stream;
  }

  Future<void> _start(
    StreamController<BeaconSignal> controller,
    String? target,
  ) async {
    _scanning = true;
    _results = (_scanResults ?? FlutterBluePlus.onScanResults).listen(
      (results) {
        if (!_scanning || controller.isClosed) return;
        for (final result in results) {
          if (result.rssi < -120 || result.rssi >= 0) continue;
          final id = beaconIdResolver(result).trim();
          if (id.isEmpty ||
              (target != null && target.isNotEmpty && id != target)) {
            continue;
          }
          final smoother = _smoothers.putIfAbsent(
            id,
            () => RssiMovingAverageSmoother(
              windowSize: 5,
              maxSingleSampleDelta: 10,
              lostResetThreshold: 3,
            ),
          );
          controller.add(
            _estimator.buildSignal(
              beaconId: id,
              rssi: smoother.addSample(result.rssi),
              lastDetectedAt: result.timeStamp,
            ),
          );
        }
      },
      onError: (Object error, StackTrace stack) {
        if (!controller.isClosed) controller.addError(error, stack);
        unawaited(stop());
      },
    );
    _adapter = (_adapterStates ?? FlutterBluePlus.adapterState).listen(
      (state) {
        if (!_scanning || controller.isClosed) return;
        if (state == BluetoothAdapterState.off ||
            state == BluetoothAdapterState.turningOff ||
            state == BluetoothAdapterState.unavailable ||
            state == BluetoothAdapterState.unauthorized) {
          controller.addError(
              StateError('Bluetooth 상태가 변경되어 탐색을 중지했습니다: ${state.name}'));
          unawaited(stop());
        }
      },
      onError: (Object error, StackTrace stack) {
        if (!_scanning || controller.isClosed) return;
        controller.addError(error, stack);
        unawaited(stop());
      },
    );
    try {
      await (_startScan?.call() ??
          FlutterBluePlus.startScan(
            timeout: scanTimeout,
            continuousUpdates: true,
            continuousDivisor: 1,
            oneByOne: true,
            androidUsesFineLocation: true,
            withRemoteIds: const ['C3:00:00:5C:B9:47', 'C3:00:00:5C:B9:48'],
          ));
      if (_scanning) {
        _timer = Timer(scanTimeout, () => unawaited(stop()));
      } else {
        await (_stopScan?.call() ?? FlutterBluePlus.stopScan());
      }
    } catch (error, stack) {
      if (!controller.isClosed) controller.addError(error, stack);
      await stop();
    }
  }

  @override
  Future<void> stop() => _stopTask ??= _stop();

  Future<void> _stop() async {
    _scanning = false;
    _timer?.cancel();
    await _results?.cancel();
    await _adapter?.cancel();
    try {
      await (_stopScan?.call() ?? FlutterBluePlus.stopScan());
    } finally {
      final controller = _controller;
      if (controller != null && !controller.isClosed) {
        unawaited(controller.close());
      }
    }
  }
}
