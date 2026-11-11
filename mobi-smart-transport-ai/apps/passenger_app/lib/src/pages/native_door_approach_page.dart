import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:mobi_mobile_sensors/mobi_mobile_sensors.dart';
import '../services/native_directional_cue_output.dart';
import '../services/speech_priority_coordinator.dart';
import 'door_approach_demo_page.dart';
import '../local_vision/local_vision_page.dart';

/// Isolated Android debug rehearsal. No RSSI direction, server or head tracker.
class NativeDoorApproachPage extends StatefulWidget {
  const NativeDoorApproachPage({super.key});
  @override
  State<NativeDoorApproachPage> createState() => _NativeDoorState();
}

class _NativeDoorState extends State<NativeDoorApproachPage> {
  static const _permissions =
      MethodChannel('mobi.passenger/hardware-permissions');
  final _stops = StreamController<void>.broadcast();
  StreamSubscription<BluetoothAdapterState>? _adapter;
  NativeDirectionalCueOutput? _output;
  FlutterSpeechEngine? _tts;
  bool get _allowed =>
      kDebugMode && !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  @override
  void initState() {
    super.initState();
    if (!_allowed) return;
    final output = NativeDirectionalCueOutput();
    _output = output;
    _tts = FlutterSpeechEngine.platform(
        requireOfflineKoreanVoice: true,
        requestNativeFocus: true,
        diagnostic: output.recordTtsEvent);
    _adapter = FlutterBluePlus.adapterState.listen((state) {
      if ([
        BluetoothAdapterState.off,
        BluetoothAdapterState.turningOff,
        BluetoothAdapterState.unavailable,
        BluetoothAdapterState.unauthorized
      ].contains(state)) {
        _stops.add(null);
      }
    }, onError: (Object error) => _stops.add(null));
  }

  Future<bool> _prepareScanner() async {
    final state =
        await _permissions.invokeMapMethod<String, dynamic>('request');
    return mounted &&
        state?['granted'] == true &&
        state?['locationEnabled'] == true &&
        await FlutterBluePlus.adapterState.first
                .timeout(const Duration(seconds: 3)) ==
            BluetoothAdapterState.on;
  }

  @override
  Widget build(BuildContext context) => !_allowed ||
          _output == null ||
          _tts == null
      ? const Scaffold(body: Center(child: Text('Android debug 전용 시연입니다.')))
      : DoorApproachDemoPage(
          output: _output!,
          tts: _tts!,
          targetId: 'C3:00:00:5C:B9:47',
          transportStops: _stops.stream,
          prepareScanner: _prepareScanner,
          cameraBuilder: (input) => LocalVisionPage(
              embedded: true,
              rearCameraOnly: true,
              bundledModel: true,
              sessionNow: input.now,
              sessionCurrent: input.isCurrent,
              onInputUnavailable: input.onUnavailable,
              onResult: (observation) async {
                input.onFrame(observation.toDetectionResult(),
                    Duration(microseconds: observation.frame.receivedMicros));
              }),
          scannerFactory: () => FlutterBlueBeaconScanner(
              scanTimeout: const Duration(minutes: 5),
              beaconIdResolver: (result) =>
                  result.device.remoteId.str.toUpperCase()));
  @override
  void dispose() {
    unawaited(_adapter?.cancel());
    unawaited(_stops.close());
    super.dispose();
  }
}
