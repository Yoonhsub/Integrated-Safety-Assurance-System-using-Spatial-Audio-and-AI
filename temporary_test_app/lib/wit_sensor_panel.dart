import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'wit_sensor_protocol.dart';
import 'direction_audio_panel.dart';
import 'direction_pan.dart';

const witSensorMac = 'F1:35:40:62:CD:43';

class WitSensorPanel extends StatefulWidget {
  const WitSensorPanel({
    super.key,
    required this.ensureReady,
    this.beaconRssi,
    this.beaconSeenAt,
    this.beaconName = 'A (…47)',
  });
  final Future<bool> Function() ensureReady;
  final int? beaconRssi;
  final DateTime? beaconSeenAt;
  final String beaconName;

  @override
  State<WitSensorPanel> createState() => _WitSensorPanelState();
}

class _WitSensorPanelState extends State<WitSensorPanel>
    with AutomaticKeepAliveClientMixin<WitSensorPanel>, WidgetsBindingObserver {
  @override
  bool get wantKeepAlive => true;
  final _device = BluetoothDevice.fromId(witSensorMac);
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
  int _generation = 0, _frames = 0;
  bool _connecting = false, _connected = false, _closing = false;
  bool _disposed = false;
  String _status = '센서 전원을 켜고 제조사 앱의 연결을 끊어주세요.';

  bool _current(int generation) =>
      mounted && !_disposed && generation == _generation;
  bool get _fresh =>
      _connected && _latest != null && _age.elapsedMilliseconds < 2000;

  void _refresh() {
    if (mounted && !_disposed) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ticker = Timer.periodic(
      const Duration(milliseconds: 150),
      (_) => _refresh(),
    );
  }

  Future<void> _connect() async {
    if (_connecting || _connected || _closing) return;
    final generation = ++_generation;
    _connecting = true;
    _latest = null;
    _reference = null;
    _frames = 0;
    _decoder.reset();
    _yawFilter.reset();
    _filteredYaw = null;
    _status = '권한 확인 중…';
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
    _refresh();
    try {
      await _notifications?.cancel();
      await _connection?.cancel();
      _notifications = null;
      _connection = null;
      await _device.disconnect().timeout(const Duration(seconds: 5));
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
            const SelectableText(witSensorMac),
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
                  onPressed: _connecting || _connected || _closing
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
                      ? () => setState(() => _reference = _filteredYaw!)
                      : null,
                  child: const Text('현재 Z를 기준각으로'),
                ),
              ],
            ),
            const Text(
              '기준각은 이 앱에서만 적용됩니다. 장착 방향을 확인하기 전에는 Z를 머리의 좌우 방향으로 확정하지 않습니다.',
            ),
            DirectionAudioPanel(
              key: const ValueKey('direction-audio'),
              z: _filteredYaw,
              reference: _reference,
              fresh: _fresh,
              sensorAgeMs: _age.elapsedMilliseconds,
              beaconRssi: widget.beaconRssi,
              beaconSeenAt: widget.beaconSeenAt,
              beaconName: widget.beaconName,
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
