import 'hardware_test_settings.dart';
import 'compact_control_surface.dart';
import 'obstacle_cue_input.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'wit_sensor_protocol.dart';
import 'direction_audio_panel.dart';
import 'direction_pan.dart';
import 'spatial_warning_check_panel.dart';
import '../../services/head_tracking_direction.dart';

const witSensorMac = 'F1:35:40:62:CD:43';

class WitSensorPanel extends StatefulWidget {
  const WitSensorPanel({
    super.key,
    required this.ensureReady,
    this.beaconRssi,
    this.beaconSeenAt,
    this.beaconName = '버스 A',
    this.busAngle = -90,
    this.warning = false,
    this.busEnabled = true,
    this.audioScope = '',
    this.stationaryBeacon = false,
    this.obstacles,
    this.sessionNow,
    this.stateOnly = false,
    this.compact = false,
    this.allowConfiguration = false,
    this.settingsStore,
  });
  final Future<bool> Function() ensureReady;
  final int? beaconRssi;
  final DateTime? beaconSeenAt;
  final String beaconName;
  final double busAngle;
  final bool warning, busEnabled;
  final String audioScope;
  final bool stationaryBeacon;
  final ObstacleCueSnapshot? obstacles;
  final Duration Function()? sessionNow;
  final bool stateOnly;
  final bool compact;
  final bool allowConfiguration;
  final HardwareTestSettingsStore? settingsStore;

  @override
  State<WitSensorPanel> createState() => _WitSensorPanelState();
}

class _WitSensorPanelState extends State<WitSensorPanel>
    with AutomaticKeepAliveClientMixin<WitSensorPanel>, WidgetsBindingObserver {
  @override
  bool get wantKeepAlive => true;
  BluetoothDevice _device = BluetoothDevice.fromId(witSensorMac);
  String _address = witSensorMac;
  late final HardwareTestSettingsStore _settings;
  bool _loadingSettings = false, _savingSettings = false, _settingsOpen = false;
  bool _settingsLoadFailed = false;
  bool get _idle => !_connecting && !_connected && !_closing;
  bool get _configurationReady =>
      !_loadingSettings && !_savingSettings && !_settingsOpen;
  final _decoder = WitSensorDecoder();
  final _age = Stopwatch();
  final _clock = Stopwatch()..start();
  final _yawFilter = YawFilter();
  double? _filteredYaw;
  StreamSubscription<List<int>>? _notifications;
  StreamSubscription<BluetoothConnectionState>? _connection;
  Timer? _ticker;
  WitAngles? _latest;
  double? _reference;
  int _generation = 0, _frames = 0, _referenceRevision = 0;
  bool _connecting = false, _connected = false, _closing = false;
  bool _disposed = false;
  bool _listeningCheck = false;
  String _status = '센서 전원을 켜고 제조사 앱의 연결을 끊어주세요.';

  bool _current(int generation) =>
      mounted && !_disposed && generation == _generation;
  bool get _fresh =>
      _connected && _latest != null && _age.elapsedMilliseconds < 2000;

  void _refresh() {
    if (_connected &&
        _latest != null &&
        !_fresh &&
        sharedHeadTrackingState.snapshot.status != HeadTrackingStatus.stale) {
      _publish(HeadTrackingStatus.stale, message: '센서 데이터 만료');
    }
    if (mounted && !_disposed) setState(() {});
  }

  void _publish(HeadTrackingStatus status, {String? message}) {
    sharedHeadTrackingState.publish(HeadTrackingSnapshot(
      status: status,
      rawYaw: _latest?.z,
      filteredYaw: _filteredYaw,
      referenceYaw: _reference,
      receivedAt: _latest == null ? null : DateTime.now().toUtc(),
      message: message ?? _status,
    ));
  }

  @override
  void initState() {
    super.initState();
    _settings =
        widget.settingsStore ?? SharedPreferencesHardwareTestSettingsStore();
    if (widget.allowConfiguration) unawaited(_loadSettings());
    WidgetsBinding.instance.addObserver(this);
    _ticker = Timer.periodic(
      const Duration(milliseconds: 150),
      (_) => _refresh(),
    );
  }

  void _applyAddress(String address) {
    _settingsLoadFailed = false;
    ++_generation;
    ++_referenceRevision;
    _latest = null;
    _reference = null;
    _filteredYaw = null;
    _frames = 0;
    _decoder.reset();
    _yawFilter.reset();
    _age
      ..stop()
      ..reset();
    _status = 'WT 주소 적용 완료. 센서 연결을 눌러 연결하세요.';
    _publish(HeadTrackingStatus.disconnected);
    _address = address;
    _device = BluetoothDevice.fromId(address);
  }

  Future<void> _loadSettings() async {
    _loadingSettings = true;
    _status = 'WT 주소 설정 불러오는 중';
    try {
      final saved = await _settings.loadWit();
      if (!mounted || _disposed) return;
      final normalized = saved == null
          ? witSensorMac
          : HardwareTestSettings.normalizeMac(saved);
      if (normalized == null) {
        _settingsLoadFailed = true;
        _status = '저장된 WT 주소 오류: 연결이 차단되었습니다. 주소를 저장하거나 기본값을 복원하세요.';
      } else {
        _applyAddress(normalized);
      }
    } catch (_) {
      if (mounted && !_disposed) {
        _settingsLoadFailed = true;
        _status = 'WT 주소 읽기 실패: 연결이 차단되었습니다. 주소를 저장하거나 기본값을 복원하세요.';
      }
    } finally {
      _loadingSettings = false;
      _refresh();
    }
  }

  Future<void> _configure() async {
    if (!widget.allowConfiguration || !_idle || !_configurationReady) return;
    _settingsOpen = true;
    _refresh();
    final input = TextEditingController(text: _address);
    String? error;
    try {
      final route = DialogRoute<void>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) =>
              StatefulBuilder(builder: (context, update) {
                Future<void> save(bool reset) async {
                  if (_savingSettings || !_idle || _disposed) return;
                  final address = reset
                      ? witSensorMac
                      : HardwareTestSettings.normalizeMac(input.text);
                  if (address == null) {
                    update(
                        () => error = 'AA:BB:CC:DD:EE:FF 형식의 MAC 주소를 입력하세요.');
                    return;
                  }
                  _savingSettings = true;
                  update(() => error = null);
                  _refresh();
                  try {
                    if (reset) {
                      await _settings.resetWit();
                    } else {
                      await _settings.saveWit(address);
                    }
                    if (!mounted || _disposed || !dialogContext.mounted) return;
                    if (!_idle) throw StateError('Sensor is not idle');
                    _applyAddress(address);
                    Navigator.pop(dialogContext);
                  } catch (_) {
                    if (dialogContext.mounted && !_disposed) {
                      update(
                          () => error = '저장하지 못했습니다. 기존 주소를 유지합니다. 다시 시도하세요.');
                    }
                  } finally {
                    _savingSettings = false;
                    if (dialogContext.mounted && !_disposed) update(() {});
                    _refresh();
                  }
                }

                return PopScope(
                    canPop: !_savingSettings,
                    child: AlertDialog(
                        title: const Text('WT 주소 설정'),
                        content: SingleChildScrollView(
                            child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                              const Text(
                                  '이 기기에만 저장합니다. 연결 중에는 변경할 수 없습니다. 주소를 바꾼 뒤 다시 연결하고 정면을 보정하세요.'),
                              TextField(
                                  controller: input,
                                  enabled: !_savingSettings,
                                  decoration: InputDecoration(
                                      labelText: 'WT MAC 주소',
                                      errorText: error)),
                              if (_savingSettings) const Text('저장 중'),
                            ])),
                        actions: [
                          TextButton(
                              onPressed: _savingSettings
                                  ? null
                                  : () => Navigator.pop(dialogContext),
                              child: const Text('취소')),
                          TextButton(
                              onPressed:
                                  _savingSettings ? null : () => save(true),
                              child: const Text('기본값 복원')),
                          FilledButton(
                              onPressed:
                                  _savingSettings ? null : () => save(false),
                              child: const Text('저장')),
                        ]));
              }));
      await Navigator.of(context, rootNavigator: true).push(route);
      await route.completed;
    } finally {
      input.dispose();
      _settingsOpen = false;
      _refresh();
    }
  }

  Future<void> _connect() async {
    if (!_idle || !_configurationReady || _settingsLoadFailed) return;
    final generation = ++_generation;
    _connecting = true;
    _latest = null;
    _reference = null;
    _frames = 0;
    _decoder.reset();
    _yawFilter.reset();
    _filteredYaw = null;
    _status = '권한 확인 중…';
    _publish(HeadTrackingStatus.connecting);
    _refresh();
    try {
      if (!await widget.ensureReady()) {
        if (_current(generation)) {
          _status = '먼저 주변 기기/정확한 위치 권한과 위치 기능을 확인해주세요.';
        }
        return;
      }
      if (!_current(generation)) return;
      _status = 'WT901BLE68에 연결 중…';
      _refresh();
      _connection = _device.connectionState.listen(
        (state) {
          if (_current(generation) &&
              _connected &&
              state == BluetoothConnectionState.disconnected) {
            unawaited(_close('센서 연결이 끊겼습니다. 다시 연결해주세요.'));
          }
        },
        onError: (Object e) {
          if (_current(generation)) {
            unawaited(_close('연결 상태 확인 실패: $e'));
          }
        },
      );
      await _device.connect(timeout: const Duration(seconds: 15), mtu: null);
      if (!_current(generation)) return;
      _connected = true;
      _status = '센서 데이터 서비스 확인 중…';
      _publish(HeadTrackingStatus.connectedUncalibrated);
      _refresh();
      final services = await _device.discoverServices().timeout(
            const Duration(seconds: 15),
          );
      if (!_current(generation)) return;
      BluetoothCharacteristic? characteristic;
      for (final service in services) {
        debugPrint(
          'MOBI_WIT_GATT ${service.uuid} ${service.characteristics.map((c) => c.uuid).join(',')}',
        );
        if (service.uuid != Guid('0000ffe5-0000-1000-8000-00805f9a34fb')) {
          continue;
        }
        for (final candidate in service.characteristics) {
          if (candidate.uuid == Guid('0000ffe4-0000-1000-8000-00805f9a34fb') &&
              (candidate.properties.notify || candidate.properties.indicate)) {
            characteristic = candidate;
          }
        }
      }
      if (characteristic == null) {
        throw StateError('FFE5/FFE4 알림 특성을 찾지 못했습니다. 센서 규격 확인이 필요합니다.');
      }
      _notifications = characteristic.onValueReceived.listen(
        (bytes) {
          if (!_current(generation)) return;
          final readings = _decoder.add(bytes);
          if (readings.isEmpty) return;
          for (final reading in readings) {
            _filteredYaw = _yawFilter.add(reading.z, _clock.elapsed);
          }
          _latest = readings.last;
          _frames += readings.length;
          _age
            ..reset()
            ..start();
          _status = '센서 각도 수신 중';
          _publish(_reference == null
              ? HeadTrackingStatus.connectedUncalibrated
              : HeadTrackingStatus.ready);
          if (_frames == 1 || _frames % 20 == 0) {
            debugPrint(
              'MOBI_WIT_ANGLES frames=$_frames X=${_latest!.x} Y=${_latest!.y} Z=${_latest!.z}',
            );
          }
        },
        onError: (Object e) {
          if (_current(generation)) unawaited(_close('센서 알림 수신 실패: $e'));
        },
      );
      await characteristic
          .setNotifyValue(true)
          .timeout(const Duration(seconds: 10));
      if (!_current(generation)) return;
      if (_latest == null) _status = '연결됨 · 55 61 각도 데이터 대기 중';
    } catch (e) {
      if (_current(generation)) await _close('센서 연결 실패: $e');
    } finally {
      if (_current(generation)) {
        _connecting = false;
        _refresh();
      }
    }
  }

  Future<void> _close(String message) async {
    if (_closing) return;
    _closing = true;
    ++_generation;
    _connecting = false;
    _connected = false;
    _latest = null;
    _reference = null;
    _decoder.reset();
    _yawFilter.reset();
    _filteredYaw = null;
    _age.stop();
    _status = message;
    _publish(message.contains('실패') || message.contains('오류')
        ? HeadTrackingStatus.error
        : HeadTrackingStatus.disconnected);
    _refresh();
    try {
      final notifications = _notifications;
      final connection = _connection;
      _notifications = null;
      _connection = null;
      // Attempt every cleanup even if stream cancellation fails.
      await Future.wait<void>([
        if (notifications != null) Future<void>.sync(notifications.cancel),
        if (connection != null) Future<void>.sync(connection.cancel),
        Future<void>.sync(
            () => _device.disconnect().timeout(const Duration(seconds: 5))),
      ]);
    } catch (e) {
      _status = '$message (연결 정리 확인 필요: $e)';
    } finally {
      _closing = false;
      _refresh();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused && (_connecting || _connected)) {
      unawaited(_close('화면을 벗어나 센서 연결을 종료했습니다.'));
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final reading = _latest;
    if (widget.compact && widget.stateOnly) {
      return CompactControlSurface(
          label: 'WT 센서',
          child: Card(
              child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        const Expanded(child: Text('WT 자세 센서')),
                        if (widget.allowConfiguration)
                          IconButton(
                              tooltip: 'WT 주소 설정',
                              icon: const Icon(Icons.settings),
                              onPressed: _idle && _configurationReady
                                  ? _configure
                                  : null),
                        IconButton(
                            tooltip: '센서 상태 자세히',
                            icon: const Icon(Icons.info_outline),
                            onPressed: () => showDialog<void>(
                                context: context,
                                builder: (context) => AlertDialog(
                                      title: const Text('WT 센서 상태'),
                                      content: SingleChildScrollView(
                                          child: Text(
                                              '$_address\n$_status\n수신 $_frames 프레임\nYaw: ${_filteredYaw?.toStringAsFixed(2) ?? "없음"}°\n기준: ${_reference?.toStringAsFixed(2) ?? "미설정"}\n정면을 보고 기준을 설정하세요. 화면 전환은 센서 연결을 끊지 않습니다.')),
                                      actions: [
                                        TextButton(
                                            onPressed: () =>
                                                Navigator.pop(context),
                                            child: const Text('닫기'))
                                      ],
                                    ))),
                      ]),
                      if (_settingsLoadFailed)
                        const Text('주소 설정 오류 · 설정에서 저장/복원 필요'),
                      Text(_connected
                          ? (_fresh ? '연결됨 · 실시간 수신' : '연결됨 · 최신 데이터 없음')
                          : (_connecting ? '연결 중' : '연결 안 됨')),
                      Row(children: [
                        Expanded(
                            child: FilledButton(
                                onPressed: !_idle ||
                                        !_configurationReady ||
                                        _settingsLoadFailed
                                    ? null
                                    : _connect,
                                child: const Text('센서 연결'))),
                        const SizedBox(width: 8),
                        Expanded(
                            child: OutlinedButton(
                                onPressed: _connecting || _connected
                                    ? () => unawaited(_close('센서 연결을 종료했습니다.'))
                                    : null,
                                child: const Text('연결 중지')))
                      ]),
                      SizedBox(
                          width: double.infinity,
                          child: OutlinedButton(
                              onPressed: _fresh
                                  ? () => setState(() {
                                        _reference = _filteredYaw!;
                                        _referenceRevision++;
                                        _publish(HeadTrackingStatus.ready,
                                            message: '정면 설정 완료');
                                      })
                                  : null,
                              child: const Text('현재 방향을 정면으로 설정'))),
                    ],
                  ))));
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '자세 센서 · WT901BLE68',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            SelectableText(_address),
            if (widget.allowConfiguration)
              OutlinedButton(
                  onPressed: _idle && _configurationReady ? _configure : null,
                  child: const Text('WT 주소 설정')),
            Text(_status),
            Text('각도 프레임: $_frames개'),
            const SizedBox(height: 8),
            if (reading != null) ...[
              Text('AngleX: ${reading.x.toStringAsFixed(2)}°'),
              Text('AngleY: ${reading.y.toStringAsFixed(2)}°'),
              Text('필터 Yaw: ${_filteredYaw?.toStringAsFixed(2)}°'),
              Text(
                'AngleZ: ${reading.z.toStringAsFixed(2)}°',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              Text(
                _fresh ? '실시간 수신 중' : '수신 지연 · 마지막 각도값',
                style: TextStyle(color: _fresh ? Colors.teal : Colors.brown),
              ),
              if (_reference != null && _fresh)
                Text(
                  '기준 대비 Z: ${relativeAngle(_filteredYaw!, _reference!).toStringAsFixed(2)}°',
                ),
            ] else
              const Text('아직 각도를 수신하지 않았습니다.'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton(
                  onPressed:
                      !_idle || !_configurationReady || _settingsLoadFailed
                          ? null
                          : _connect,
                  child: const Text('센서 연결'),
                ),
                OutlinedButton(
                  onPressed: _connecting || _connected
                      ? () => unawaited(_close('센서 연결을 종료했습니다.'))
                      : null,
                  child: const Text('센서 연결 해제'),
                ),
                OutlinedButton(
                  onPressed: _fresh
                      ? () => setState(() {
                            _reference = _filteredYaw!;
                            _referenceRevision++;
                            _publish(HeadTrackingStatus.ready,
                                message: '정면 보정 완료');
                          })
                      : null,
                  child: const Text('도로 정면을 기준으로 설정'),
                ),
              ],
            ),
            const Text(
              '정류장에서 도로 정면을 보고 기준을 설정하세요. 센서를 머리에 고정하고 좌우 부호를 확인하세요.',
            ),
            if (!widget.stateOnly && !_listeningCheck)
              DirectionAudioPanel(
                key: const ValueKey('direction-audio'),
                z: _filteredYaw,
                reference: _reference,
                fresh: _fresh,
                sensorAgeMs: _age.elapsedMilliseconds,
                beaconRssi: widget.beaconRssi,
                beaconSeenAt: widget.beaconSeenAt,
                beaconName: widget.beaconName,
                busAngle: widget.busAngle,
                warning: widget.warning,
                busEnabled: widget.busEnabled,
                audioScope:
                    '${widget.audioScope}/$_generation/$_referenceRevision',
                stationaryBeacon: widget.stationaryBeacon,
                obstacles: widget.obstacles,
                sessionNow: widget.sessionNow,
              ),
            if (!widget.stateOnly)
              ExpansionTile(
                key: const ValueKey('spatial-listening-check'),
                title: const Text('공간 경고음 청취 확인 (검증용)'),
                onExpansionChanged: (open) =>
                    setState(() => _listeningCheck = open),
                children: [
                  if (_listeningCheck)
                    SpatialWarningCheckPanel(
                      z: _filteredYaw,
                      reference: _reference,
                      fresh: _fresh,
                      sensorAgeMs: _age.elapsedMilliseconds,
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _ticker?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    if (_connecting ||
        _connected ||
        _notifications != null ||
        _connection != null) {
      unawaited(_close(''));
    }
    super.dispose();
  }
}
