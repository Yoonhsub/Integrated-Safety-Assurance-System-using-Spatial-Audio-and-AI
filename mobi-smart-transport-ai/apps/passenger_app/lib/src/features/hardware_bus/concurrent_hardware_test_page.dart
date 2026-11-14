import 'hardware_test_settings.dart';
import 'compact_control_surface.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobi_mobile_sensors/mobi_mobile_sensors.dart';
import '../../services/native_directional_cue_output.dart';
import '../../services/spatial_verification_engine.dart';
import '../../services/speech_priority_coordinator.dart';
import 'continuous_beacon_scanner.dart';
import 'wit_sensor_panel.dart';
import 'concurrent_camera_panel.dart';
import 'concurrent_test_control.dart';

typedef ConcurrentPanelBuilder = Widget Function(
    SpeechPriorityCoordinator,
    SpatialVerificationEngine,
    bool Function(),
    Future<bool> Function(Object, String, bool Function()));

/// Temporary local hardware workspace. No cloud writes or vehicle assertions.
class ConcurrentHardwareTestPage extends StatefulWidget {
  const ConcurrentHardwareTestPage(
      {super.key,
      this.engine,
      this.scannerFactory,
      this.ensurePermission,
      this.cameraBuilder,
      this.sensorBuilder,
      this.settingsStore});
  final SpatialVerificationEngine? engine;
  final HardwareTestSettingsStore? settingsStore;
  final BeaconScanner Function(String mac)? scannerFactory;
  final Future<bool> Function()? ensurePermission;
  final ConcurrentPanelBuilder? cameraBuilder;
  final Widget Function(Future<bool> Function())? sensorBuilder;
  @override
  State<ConcurrentHardwareTestPage> createState() =>
      _ConcurrentHardwareTestPageState();
}

class _ConcurrentHardwareTestPageState extends State<ConcurrentHardwareTestPage>
    with WidgetsBindingObserver {
  final _route = TextEditingController(), _mac = TextEditingController();
  final _busOwner = Object();
  late final HardwareTestSettingsStore _settings;
  bool _settingsLoading = true, _settingsSaving = false;
  final _gate = ConcurrentObservationGate();
  late final SpatialVerificationEngine _engine;
  late final SpeechPriorityCoordinator _priority;
  Future<void>? _stopTask;
  BeaconScanner? _scanner;
  StreamSubscription<BeaconSignal>? _signals;
  Timer? _loss;
  TemporaryBusTarget? _target;
  DateTime? _lastSeen, _watermark;
  bool _running = false,
      _starting = false,
      _stopping = false,
      _voice = false,
      _announced = false,
      _announcing = false;
  bool _foreground = true, _disposed = false;
  int _scanRevision = 0, _voiceRevision = 0;
  String _status = '미시작 · 번호와 실제 비콘 MAC을 직접 등록하세요.';
  bool get _current => mounted && !_disposed && _foreground;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.engine != null) {
      _engine = widget.engine!;
    } else {
      final output = NativeDirectionalCueOutput();
      _engine = SpatialVerificationEngine(
          output,
          FlutterSpeechEngine.platform(
              requireOfflineKoreanVoice: true,
              requestNativeFocus: true,
              diagnostic: output.recordTtsEvent),
          allowDirectTestCommands: false);
    }
    _priority = SpeechPriorityCoordinator(_engine);
    _settings =
        widget.settingsStore ?? SharedPreferencesHardwareTestSettingsStore();
    unawaited(_loadSettings());
  }

  Future<void> _loadSettings() async {
    try {
      final pairing = await _settings.loadBus();
      if (!mounted || _disposed) return;
      if (pairing != null) {
        _route.text = pairing.routeNo;
        _mac.text = pairing.mac;
        _status = '저장된 시연 연결을 불러왔습니다. 탐색은 직접 시작하세요.';
      }
    } catch (_) {
      if (mounted && !_disposed) {
        _status = '저장 설정 읽기 실패. 번호·MAC 설정에서 다시 저장하거나 초기화하세요.';
      }
    } finally {
      if (mounted && !_disposed) setState(() => _settingsLoading = false);
    }
  }

  Future<bool> _permission() async {
    if (widget.ensurePermission != null) return widget.ensurePermission!();
    final p = await const MethodChannel('mobi.passenger/hardware-permissions')
        .invokeMapMethod<String, dynamic>('request');
    return p?['granted'] == true && p?['locationEnabled'] == true;
  }

  Future<bool> _play(Object owner, String command, bool Function() valid) =>
      _gate.run(() => _priority.speakObservation(
          owner, command, () => _current && valid()));
  void _show(String text) {
    if (_current) setState(() => _status = text);
  }

  Future<void> _startScan() async {
    if (_settingsLoading ||
        _settingsSaving ||
        _running ||
        _starting ||
        _stopping ||
        !_current) {
      return;
    }
    final target = TemporaryBusTarget.parse(_route.text, _mac.text);
    if (target == null) {
      _show('버스 번호와 올바른 실제 Android MAC을 입력하세요. 임의 매핑은 생성하지 않습니다.');
      return;
    }
    final revision = ++_scanRevision;
    setState(() => _starting = true);
    try {
      final permitted = await _permission();
      if (!_current || revision != _scanRevision) return;
      if (!permitted) {
        _show('BLE 권한과 위치 서비스를 확인하세요.');
        return;
      }
      _target = target;
      _announced = false;
      _watermark = null;
      _lastSeen = null;
      final scanner = widget.scannerFactory?.call(target.mac) ??
          ContinuousBeaconScanner(
              beaconIdResolver: (r) => r.device.remoteId.str.toUpperCase(),
              scanTimeout: const Duration(minutes: 5),
              remoteIds: [target.mac]);
      _scanner = scanner;
      setState(() {
        _running = true;
        _status = '등록 MAC 스캔 중 · 실제 차량 접근 판정 아님';
      });
      _signals = scanner.scan(targetBeaconId: target.mac).listen((signal) {
        if (!_current ||
            !_running ||
            revision != _scanRevision ||
            !target.matches(signal, DateTime.now())) {
          return;
        }
        if (_watermark != null && !signal.lastDetectedAt.isAfter(_watermark!)) {
          return;
        }
        if (_lastSeen != null &&
            signal.lastDetectedAt.difference(_lastSeen!) >=
                const Duration(seconds: 3)) {
          _announced = false;
        }
        _watermark = _lastSeen = signal.lastDetectedAt;
        _show(
            '시연 매핑 일치: ${target.routeNo}번 · ${target.mac} · ${signal.rssi} dBm · 거리 UNKNOWN');
        if (_voice && !_announced && !_announcing) {
          unawaited(_announce(revision, target));
        }
      }, onError: (Object e) {
        if (_current && revision == _scanRevision) {
          unawaited(_stopScan('스캔 오류 · 권한/Bluetooth를 확인하고 다시 시작하세요.'));
        }
      }, onDone: () {
        if (_running && revision == _scanRevision) {
          unawaited(_stopScan('스캔 종료 · 다시 시작할 수 있습니다.'));
        }
      });
      _loss = Timer.periodic(const Duration(seconds: 1), (_) {
        if (_lastSeen != null &&
            DateTime.now().difference(_lastSeen!) >=
                const Duration(seconds: 3)) {
          _lastSeen = null;
          _announced = false;
          _voiceRevision++;
          unawaited(_stopBusVoice());
          _show('등록 비콘 소실 · 재수신 대기');
        }
      });
    } catch (_) {
      if (revision == _scanRevision) {
        await _stopScan('스캔 시작 실패 · Bluetooth와 권한을 확인하세요.');
      }
    } finally {
      if (mounted && !_disposed && revision == _scanRevision) {
        setState(() => _starting = false);
      }
    }
  }

  Future<void> _announce(int scan, TemporaryBusTarget target) async {
    _announcing = true;
    final voice = _voiceRevision;
    bool valid() =>
        _current &&
        _running &&
        _voice &&
        scan == _scanRevision &&
        voice == _voiceRevision &&
        identical(target, _target) &&
        _lastSeen != null &&
        DateTime.now().difference(_lastSeen!) < const Duration(seconds: 3);
    try {
      final ok = await _play(_busOwner, target.announcement, valid);
      if (ok && valid()) _announced = true;
    } catch (_) {
      _show('버스 음성 출력 실패 · 스캔은 계속합니다.');
    } finally {
      _announcing = false;
    }
  }

  Future<void> _stopBusVoice() async {
    try {
      await _priority.stopObservation(_busOwner);
    } catch (_) {
      _show('오디오 중지 확인 실패 — 소리를 다시 중지한 뒤 재시도하세요.');
    }
  }

  Future<void> _stopScan(String status) => _stopTask ??=
      _finishStopScan(status).whenComplete(() => _stopTask = null);

  Future<void> _finishStopScan(String status) async {
    if (_stopping) return;
    _stopping = true;
    ++_scanRevision;
    ++_voiceRevision;
    _running = false;
    _starting = false;
    _lastSeen = null;
    _announced = false;
    _loss?.cancel();
    _loss = null;
    final sub = _signals;
    _signals = null;
    final scanner = _scanner;
    _scanner = null;
    try {
      await Future.wait<void>([
        Future<void>.sync(() => _priority.stopObservation(_busOwner)),
        if (sub != null) Future<void>.sync(sub.cancel),
        if (scanner != null) Future<void>.sync(scanner.stop)
      ]);
    } catch (_) {
      status = 'BLE 종료 확인 실패 · Bluetooth 상태를 확인하세요.';
    } finally {
      _stopping = false;
      _show(status);
    }
  }

  void _toggleVoice(bool value) {
    setState(() => _voice = value);
    _voiceRevision++;
    if (!value) unawaited(_stopBusVoice());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) {
      _voice = false;
      unawaited(_stopScan('백그라운드 · 스캔 종료'));
    }
  }

  int _view = 0;
  Future<void> _pairing() async {
    if (_settingsLoading || _settingsSaving) return;
    final route = TextEditingController(text: _route.text);
    final mac = TextEditingController(text: _mac.text);
    String? error;
    bool busy = false;
    final editable = !_running && !_starting && !_stopping;
    final dialog = DialogRoute<void>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(builder: (context, update) {
              void apply(BusTestPairing value) {
                if (mounted && !_disposed) {
                  setState(() {
                    _route.text = value.routeNo;
                    _mac.text = value.mac;
                  });
                }
              }

              Future<void> persist({bool reset = false}) async {
                if (busy || !editable) return;
                final value = BusTestPairing.parse(route.text, mac.text);
                if (!reset && value == null) {
                  update(() => error = '버스 번호와 올바른 Android MAC을 입력하세요.');
                  return;
                }
                update(() {
                  busy = true;
                  error = null;
                });
                _settingsSaving = true;
                try {
                  if (reset) {
                    await _settings.resetBus();
                  } else {
                    await _settings.saveBus(value!);
                  }
                  if (!mounted || _disposed) return;
                  if (reset) {
                    setState(() {
                      _route.clear();
                      _mac.clear();
                      _status = '저장된 버스 시연 연결을 초기화했습니다.';
                    });
                    route.clear();
                    mac.clear();
                  } else {
                    apply(value!);
                    _show('시연 연결을 이 기기에 저장했습니다. 실제 버스 등록 정보가 아닙니다.');
                  }
                  if (dialogContext.mounted) {
                    update(() => error = reset ? '초기화 완료' : '로컬 저장 완료');
                  }
                } catch (_) {
                  if (dialogContext.mounted) {
                    update(() => error = '저장 변경 실패. 현재 설정을 확인하고 다시 시도하세요.');
                  }
                } finally {
                  _settingsSaving = false;
                  if (dialogContext.mounted) update(() => busy = false);
                }
              }

              return PopScope(
                  canPop: !busy,
                  child: AlertDialog(
                    title: const Text('버스 · MAC 시연 연결'),
                    content: SingleChildScrollView(
                        child:
                            Column(mainAxisSize: MainAxisSize.min, children: [
                      const Text(
                          '실제 버스 등록 정보가 아닙니다. 완료는 이번 실행에 적용하고, 저장은 이 기기에 보관합니다.'),
                      TextField(
                          controller: route,
                          enabled: editable && !busy,
                          decoration:
                              const InputDecoration(labelText: '시연 버스 번호')),
                      TextField(
                          controller: mac,
                          enabled: editable && !busy,
                          decoration: const InputDecoration(
                              labelText:
                                  '실제 Android 비콘 MAC (예: AA:BB:CC:DD:EE:FF)')),
                      if (!editable)
                        const Text('먼저 버스 탐색을 중지해야 연결 정보를 변경할 수 있습니다.'),
                      if (error != null) Text(error!),
                      if (busy) const Text('저장 변경 중…'),
                    ])),
                    actions: [
                      TextButton(
                          onPressed: editable && !busy
                              ? () => persist(reset: true)
                              : null,
                          child: const Text('저장 초기화')),
                      TextButton(
                          onPressed: editable && !busy ? persist : null,
                          child: const Text('저장')),
                      TextButton(
                          onPressed: busy
                              ? null
                              : () {
                                  final value = BusTestPairing.parse(
                                      route.text, mac.text);
                                  if (editable && value != null) apply(value);
                                  if (editable &&
                                      value == null &&
                                      (route.text.isNotEmpty ||
                                          mac.text.isNotEmpty)) {
                                    update(() => error =
                                        '버스 번호와 올바른 Android MAC을 입력하세요.');
                                    return;
                                  }
                                  Navigator.pop(context);
                                },
                          child: const Text('완료')),
                    ],
                  ));
            }));
    await Navigator.of(context).push(dialog);
    await dialog.completed;
    route.dispose();
    mac.dispose();
    if (mounted) setState(() {});
  }

  void _information() => showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
            title: const Text('동시 테스트 안내'),
            content: SingleChildScrollView(
                child: Text(
                    '임시 시연 화면입니다. 버스·WT와 카메라 화면을 바꿔도 센서 연결은 유지됩니다. 각 시작·중지는 해당 장치만 제어합니다. 소리는 겹치지 않게 한 번에 하나만 재생하며 센서는 계속 동작합니다. 실제 위험·버스 접근·통행 가능 여부를 검증하지 않습니다.\n\n버스 상태: $_status\n\n입력한 버스 번호: ${_route.text}\nMAC: ${_mac.text}')),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('닫기'))
            ],
          ));
  @override
  Widget build(BuildContext context) => Scaffold(
        resizeToAvoidBottomInset: false,
        appBar: AppBar(title: const Text('동시 테스트'), actions: [
          IconButton(
              onPressed: _information,
              tooltip: '동시 테스트 안내 및 상세 상태',
              icon: const Icon(Icons.info_outline)),
        ]),
        body: SafeArea(
            child: Column(children: [
          Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(children: [
                Expanded(
                    child: FilledButton.tonal(
                        onPressed: () => setState(() => _view = 0),
                        child: Text('1 버스·WT${_view == 0 ? " · 선택" : ""}'))),
                const SizedBox(width: 8),
                Expanded(
                    child: FilledButton.tonal(
                        onPressed: () => setState(() => _view = 1),
                        child: Text('2 카메라${_view == 1 ? " · 선택" : ""}'))),
              ])),
          Expanded(
              child: IndexedStack(index: _view, children: [
            Padding(
                padding: const EdgeInsets.all(8),
                child: Column(children: [
                  CompactControlSurface(
                      label: '버스 시연',
                      child: Card(
                          child: Padding(
                              padding: const EdgeInsets.all(8),
                              child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Row(children: [
                                      Expanded(
                                          child: Text(_settingsLoading
                                              ? '저장 설정 불러오는 중'
                                              : _running
                                                  ? '버스 시연 · 탐색 중'
                                                  : '버스 시연 · 대기')),
                                      TextButton(
                                          onPressed: _settingsLoading ||
                                                  _settingsSaving
                                              ? null
                                              : _pairing,
                                          child: const Text('번호·MAC 설정'))
                                    ]),
                                    Text(
                                        _route.text.isEmpty
                                            ? '번호와 실제 MAC을 먼저 등록하세요'
                                            : '${_route.text}번 · 수동 MAC 시연 연결',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis),
                                    Row(children: [
                                      Expanded(
                                          child: FilledButton(
                                              onPressed: _settingsLoading ||
                                                      _settingsSaving ||
                                                      _running ||
                                                      _starting ||
                                                      _stopping
                                                  ? null
                                                  : _startScan,
                                              child: const Text('버스 탐색 시작'))),
                                      const SizedBox(width: 8),
                                      Expanded(
                                          child: OutlinedButton(
                                              onPressed: _running || _starting
                                                  ? () => unawaited(_stopScan(
                                                      '사용자가 버스 탐색을 중지했습니다.'))
                                                  : null,
                                              child: const Text('버스 탐색 중지')))
                                    ]),
                                    SwitchListTile(
                                        contentPadding: EdgeInsets.zero,
                                        value: _voice,
                                        onChanged: _toggleVoice,
                                        title: const Text('버스 시연 음성 켜기')),
                                    Text(_status,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis),
                                  ])))),
                  KeyedSubtree(
                      key: const ValueKey('concurrent-wt'),
                      child: widget.sensorBuilder?.call(_permission) ??
                          WitSensorPanel(
                              ensureReady: _permission,
                              stateOnly: true,
                              compact: true,
                              allowConfiguration: true,
                              settingsStore: _settings)),
                ])),
            Padding(
                padding: const EdgeInsets.all(8),
                child: KeyedSubtree(
                    key: const ValueKey('concurrent-camera'),
                    child: widget.cameraBuilder
                            ?.call(_priority, _engine, () => _current, _play) ??
                        ConcurrentCameraPanel(
                            priority: _priority,
                            engine: _engine,
                            isCurrent: () => _current,
                            playObservation: _play,
                            compact: true))),
          ])),
        ])),
      );
  @override
  void dispose() {
    _disposed = true;
    _foreground = false;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(() async {
      await _stopScan('');
      try {
        await _engine.dispose();
      } catch (error, stack) {
        FlutterError.reportError(FlutterErrorDetails(
            exception: error,
            stack: stack,
            library: 'concurrent hardware cleanup'));
      } finally {
        _priority.dispose();
      }
    }());
    _route.dispose();
    _mac.dispose();
    super.dispose();
  }
}
