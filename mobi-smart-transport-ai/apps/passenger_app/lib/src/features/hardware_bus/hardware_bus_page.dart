import 'dart:async';
import 'package:flutter/foundation.dart';
import 'bus_passage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobi_mobile_sensors/mobi_mobile_sensors.dart';
import 'continuous_beacon_scanner.dart';
import 'wit_sensor_panel.dart';

const beaconA = 'C3:00:00:5C:B9:47';
const beaconB = 'C3:00:00:5C:B9:48';

class HardwareBusPage extends StatefulWidget {
  const HardwareBusPage({super.key, this.scannerFactory});
  final BeaconScanner Function(BeaconIdResolver)? scannerFactory;
  @override
  State<HardwareBusPage> createState() => _HardwareBusPageState();
}

class _HardwareBusPageState extends State<HardwareBusPage>
    with WidgetsBindingObserver {
  static const _permissions =
      MethodChannel('mobi.passenger/hardware-permissions');
  StreamSubscription<BeaconSignal>? _subscription;
  BeaconScanner? _scanner;
  Timer? _deadline, _ticker;
  final Map<String, BeaconSignal> _signals = {};
  final Map<String, DateTime> _radioTimes = {};
  final Map<String, int> _rawRssi = {};
  final Map<String, int> _receivedCounts = {};
  DateTime? _endsAt;
  Duration _scanDuration = const Duration(seconds: 15);
  String _toneBeaconMac = beaconA;
  final _clock = Stopwatch()..start();
  final _passages = {beaconA: BusPassage(), beaconB: BusPassage()};

  bool _fresh(String mac) {
    final at = _radioTimes[mac];
    final age =
        at == null ? 99999 : DateTime.now().difference(at).inMilliseconds;
    return _running && age >= 0 && age < 3000 && _signals[mac] != null;
  }

  String get _otherMac => _toneBeaconMac == beaconA ? beaconB : beaconA;
  bool get _wrongBus =>
      _fresh(_otherMac) &&
      _signals[_otherMac]!.rssi >= -60 &&
      (!_fresh(_toneBeaconMac) ||
          _signals[_otherMac]!.rssi >= _signals[_toneBeaconMac]!.rssi + 6);
  String get _audioMac => _wrongBus ? _otherMac : _toneBeaconMac;
  bool get _warning => _wrongBus;
  double get _busAngle => _passages[_audioMac]!.angle;

  bool _running = false, _busy = false;
  bool _disposed = false;
  bool _stopping = false;
  int _epoch = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  void _show(String value) {
    if (!mounted || _disposed) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(value)));
  }

  Future<bool> _ready({bool request = false}) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      _show('실제 하드웨어 연동은 Android 기기에서 사용하세요.');
      return false;
    }
    final state = await _permissions.invokeMapMethod<String, dynamic>(
      request ? 'request' : 'check',
    );
    if (state?['granted'] != true) {
      _show(
        '주변 기기와 위치 권한이 필요합니다. 위치는 정확한 위치로 허용해주세요. 거부했다면 앱 설정에서 변경할 수 있습니다.',
      );
      return false;
    }
    if (state?['locationEnabled'] != true) {
      _show('휴대폰의 위치 기능을 켜주세요.');
      return false;
    }
    return true;
  }

  Future<void> _requestPermissions() async {
    try {
      if (await _ready(request: true)) {
        _show('권한 허용 완료.');
      }
    } catch (e) {
      _show('권한 확인 실패: $e');
    }
  }

  Future<void> _start({Duration duration = const Duration(seconds: 15)}) async {
    if (_busy || _running || _stopping) return;
    setState(() => _busy = true);
    try {
      if (!await _ready() || !mounted) return;
      final epoch = ++_epoch;
      final scanner = (widget.scannerFactory ??
          (resolver) => ContinuousBeaconScanner(
                beaconIdResolver: resolver,
                scanTimeout: duration,
              ))(
        // Both E2 devices advertise the same name/UUID: use the Android MAC.
        (result) {
          final mac = result.device.remoteId.str.toUpperCase();
          if (_radioTimes[mac] != result.timeStamp) {
            _receivedCounts[mac] = (_receivedCounts[mac] ?? 0) + 1;
          }
          _radioTimes[mac] = result.timeStamp;
          _rawRssi[mac] = result.rssi;
          return mac;
        },
      );
      _scanner = scanner;
      setState(() {
        for (final passage in _passages.values) {
          passage.reset();
        }
        _signals.clear();
        _radioTimes.clear();
        _rawRssi.clear();
        _receivedCounts.clear();
        _scanDuration = duration;
        _endsAt = DateTime.now().add(duration);
        _running = true;
      });
      _subscription = scanner.scan().listen(
        (signal) {
          if (!mounted || epoch != _epoch) return;
          setState(() {
            _signals[signal.beaconId] = signal;
            _radioTimes[signal.beaconId] = signal.lastDetectedAt;
            _passages[signal.beaconId]?.observe(signal.rssi, _clock.elapsed);
          });
          if (signal.beaconId == beaconA || signal.beaconId == beaconB) {
            debugPrint(
              'MOBI_BLE_SAMPLE ${signal.beaconId} RSSI=${signal.rssi} at=${signal.lastDetectedAt.toUtc().toIso8601String()}',
            );
          }
        },
        onError: (Object e) {
          if (epoch == _epoch) {
            unawaited(_stop('스캔 실패: $e\n블루투스/권한 상태를 확인해주세요.'));
          }
        },
        onDone: () {
          if (mounted && epoch == _epoch && _running) {
            unawaited(_stop('스캔 종료. 표시된 값은 마지막 수신 기록입니다.'));
          }
        },
      );
      _deadline = Timer(
        duration,
        () => unawaited(_stop('${duration.inSeconds}초 스캔 종료. 다시 스캔할 수 있습니다.')),
      );
    } catch (e) {
      await _stop('스캔 시작 실패: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _stop(String message) async {
    if (_stopping) return;
    _stopping = true;
    ++_epoch;
    _deadline?.cancel();
    final scanner = _scanner;
    final subscription = _subscription;
    _scanner = null;
    _subscription = null;
    if (mounted && !_disposed) setState(() => _running = false);
    try {
      await scanner?.stop().timeout(const Duration(seconds: 3));
      await subscription?.cancel().timeout(const Duration(seconds: 3));
      _show(message);
    } catch (e) {
      _show('스캔 정리 확인 필요: $e. 앱을 다시 열어주세요.');
    } finally {
      _stopping = false;
      if (mounted && !_disposed) setState(() {});
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused && _running) {
      unawaited(_stop('화면을 벗어나 스캔을 중지했습니다. 다시 시작해주세요.'));
    }
  }

  Widget _card(String name, String mac) {
    final signal = _signals[mac];
    final receivedAt = _radioTimes[mac];
    final age = receivedAt == null
        ? null
        : DateTime.now().difference(receivedAt).inSeconds;
    final fresh = _fresh(mac);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('비콘 $name', style: Theme.of(context).textTheme.titleLarge),
            SelectableText(mac),
            Text('수신 횟수: ${_receivedCounts[mac] ?? 0}회'),
            const SizedBox(height: 8),
            if (signal != null) Text('RSSI (원본): ${_rawRssi[mac]} dBm'),
            Text(
              signal == null ? '아직 수신되지 않음' : 'RSSI (보정): ${signal.rssi} dBm',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            if (signal != null)
              Text('등급: ${signal.signalLevel.toJsonValue()} · 마지막 갱신 $age초 전'),
            Text(
              fresh
                  ? '최근 수신됨'
                  : signal == null
                      ? '스캔을 시작해주세요'
                      : '최근 수신 확인 안 됨 · 마지막 기록',
              style: TextStyle(color: fresh ? Colors.teal : Colors.brown),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('실기기 연동확인')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  onPressed: _running || _busy || _stopping
                      ? null
                      : _requestPermissions,
                  child: const Text('권한 허용'),
                ),
                FilledButton(
                  onPressed: _running || _busy || _stopping
                      ? null
                      : () => _start(duration: const Duration(minutes: 5)),
                  child: const Text('버스 탐색 시작 (5분)'),
                ),
                OutlinedButton(
                  onPressed: _running
                      ? () => unawaited(_stop('사용자가 스캔을 중지했습니다.'))
                      : null,
                  child: const Text('중지'),
                ),
              ],
            ),
            if (_running && _endsAt != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                    '남은 시간: ${((_endsAt!.difference(DateTime.now()).inMilliseconds + 999) ~/ 1000).clamp(0, _scanDuration.inSeconds)}초'),
              ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Text('목표 버스: '),
                DropdownButton<String>(
                  value: _toneBeaconMac,
                  items: const [
                    DropdownMenuItem(
                        value: beaconA, child: Text('502번 역할 · 비콘 A')),
                    DropdownMenuItem(
                        value: beaconB, child: Text('511번 역할 · 비콘 B')),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      setState(() {
                        _toneBeaconMac = value;
                        _passages[value]!.reset();
                      });
                    }
                  },
                ),
              ],
            ),
            WitSensorPanel(
              key: const ValueKey('wit-sensor-panel'),
              ensureReady: _ready,
              beaconRssi: _signals[_audioMac]?.rssi,
              beaconSeenAt: _running ? _radioTimes[_audioMac] : null,
              beaconName:
                  _toneBeaconMac == beaconA ? '502번 역할 · A' : '511번 역할 · B',
              busAngle: _busAngle,
              warning: _warning,
              audioScope: '$_toneBeaconMac/$_epoch',
            ),
            _card('A', beaconA),
            _card('B', beaconB),
            Text('이번 스캔에서 확인한 기기: ${_signals.length}개'),
            const SizedBox(height: 12),
            const Text(
              '비콘 A=502번/B=511번은 이 기기의 테스트 매핑입니다. RSSI는 정확한 거리나 차량 인증이 아닙니다. 방향은 왼쪽 접근·정면 정차·오른쪽 출발 가정이며 비콘의 실제 방위를 측정하지 않습니다. 실제 승차 완료는 자동 판정하지 않습니다.',
            ),
          ],
        ),
      );

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    unawaited(_stop(''));
    super.dispose();
  }
}
