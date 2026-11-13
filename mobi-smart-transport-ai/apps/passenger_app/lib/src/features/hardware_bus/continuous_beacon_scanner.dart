import 'dart:async';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:mobi_mobile_sensors/mobi_mobile_sensors.dart';

/// Private diagnostic adapter. The original project's scanner is unchanged.
class ContinuousBeaconScanner implements BeaconScanner {
  ContinuousBeaconScanner({
    required this.beaconIdResolver,
    this.scanTimeout = const Duration(seconds: 15),
    this.recoveryTarget,
  });
  final Duration scanTimeout;
  final String Function()? recoveryTarget;
  final Map<String, Duration> _packetTimes = {};

  final BeaconIdResolver beaconIdResolver;
  final _estimator = const BeaconDistanceEstimator();
  final Map<String, RssiMovingAverageSmoother> _smoothers = {};
  StreamController<BeaconSignal>? _controller;
  StreamSubscription<List<ScanResult>>? _results;
  Timer? _timer, _watchdog;
  final _clock = Stopwatch()..start();
  final _recovery = ScanRecoveryGuard();
  Duration _lastPacket = Duration.zero, _deadline = Duration.zero;
  bool _recovering = false;
  Future<void> _startRadio(Duration remaining) => FlutterBluePlus.startScan(
      timeout: remaining,
      continuousUpdates: true,
      continuousDivisor: 1,
      oneByOne: true,
      androidLegacy: true,
      androidScanMode: AndroidScanMode.lowLatency,
      androidUsesFineLocation: true,
      withRemoteIds: const ['C3:00:00:5C:B9:47', 'C3:00:00:5C:B9:48']);
  Future<void> _checkRadio() async {
    if (!_scanning ||
        _recovering ||
        !_recovery.claim(
            _clock.elapsed,
            recoveryTarget == null
                ? _lastPacket
                : (_packetTimes[recoveryTarget!()] ?? Duration.zero),
            _deadline)) {
      return;
    }
    _recovering = true;
    debugPrint(
        'MOBI_BLE_RECOVERY begin gapMs=${(_clock.elapsed - _lastPacket).inMilliseconds}');
    try {
      await FlutterBluePlus.stopScan();
      if (!_scanning) return;
      final remaining = _deadline - _clock.elapsed;
      if (remaining <= Duration.zero) return;
      await _startRadio(remaining);
      if (!_scanning) await FlutterBluePlus.stopScan();
      debugPrint(
          'MOBI_BLE_RECOVERY restart completed · awaiting actual packet');
    } catch (e, stack) {
      if (_scanning) {
        _controller?.addError(e, stack);
        unawaited(stop());
      }
    } finally {
      _recovering = false;
    }
  }

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
    _lastPacket = _clock.elapsed;
    _deadline = _clock.elapsed + scanTimeout;
    _results = FlutterBluePlus.onScanResults.listen(
      (results) {
        if (!_scanning || controller.isClosed) return;
        for (final result in results) {
          if (result.rssi < -120 || result.rssi >= 0) continue;
          final id = beaconIdResolver(result).trim();
          if (id.isEmpty ||
              (target != null && target.isNotEmpty && id != target)) {
            continue;
          }
          _lastPacket = _clock.elapsed;
          _packetTimes[id] = _lastPacket;
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
    try {
      await _startRadio(scanTimeout);
      if (_scanning) {
        _timer = Timer(scanTimeout, () => unawaited(stop()));
        _watchdog = Timer.periodic(
            const Duration(milliseconds: 500), (_) => unawaited(_checkRadio()));
      } else {
        await FlutterBluePlus.stopScan();
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
    _watchdog?.cancel();
    await _results?.cancel();
    try {
      await FlutterBluePlus.stopScan();
    } finally {
      final controller = _controller;
      if (controller != null && !controller.isClosed) {
        unawaited(controller.close());
      }
    }
  }
}

/// At most one recovery per 30 seconds; never extends the user's scan deadline.
class ScanRecoveryGuard {
  Duration? _last;
  bool claim(Duration now, Duration lastPacket, Duration deadline) {
    if (now.isNegative ||
        lastPacket > now ||
        deadline - now <= const Duration(seconds: 1) ||
        now - lastPacket < const Duration(seconds: 2) ||
        (_last != null && now - _last! < const Duration(seconds: 30))) {
      return false;
    }
    _last = now;
    return true;
  }
}
