import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobi_mobile_sensors/mobi_mobile_sensors.dart';
import 'continuous_beacon_scanner.dart';
import 'wit_sensor_panel.dart';

void main() => runApp(const BleTestApp());

const beaconA = 'C3:00:00:5C:B9:47';
const beaconB = 'C3:00:00:5C:B9:48';

class BleTestApp extends StatelessWidget {
  const BleTestApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
    home: const BleTestPage(),
  );
}

class BleTestPage extends StatefulWidget {
  const BleTestPage({super.key, this.scannerFactory});
  final BeaconScanner Function(BeaconIdResolver)? scannerFactory;
  @override
  State<BleTestPage> createState() => _BleTestPageState();
}

class _BleTestPageState extends State<BleTestPage> with WidgetsBindingObserver {
  static const _permissions = MethodChannel('mobi.temp/permissions');
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
  bool _running = false, _busy = false;
  bool _disposed = false;
  bool _stopping = false;
  int _epoch = 0;
  String _message = '비콘 두 개를 켜고 권한 허용부터 눌러주세요.';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  void _show(String value) {
    if (mounted && !_disposed) setState(() => _message = value);
  }

  Future<bool> _ready({bool request = false}) async {
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
        _show('권한 준비 완료. 블루투스를 켜고 15초 스캔을 눌러주세요.');
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
      final scanner =
          (widget.scannerFactory ??
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
        _signals.clear();
        _radioTimes.clear();
        _rawRssi.clear();
        _receivedCounts.clear();
        _scanDuration = duration;
        _endsAt = DateTime.now().add(duration);
        _running = true;
        _message = '스캔 중… A/B를 번갈아 가까이 가져와 보세요.';
      });
      _subscription = scanner.scan().listen(
        (signal) {
          if (!mounted || epoch != _epoch) return;
          setState(() => _signals[signal.beaconId] = signal);
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
    final fresh = _running && age != null && age <= 5;
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
    appBar: AppBar(title: const Text('MOBI 비콘 임시 테스트')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('Android · 비콘/자세/방향음 테스트 · v1.2.0'),
        const Text('기존 센서 모델/거리 계산 + 임시 연속 수신 어댑터'),
        const SizedBox(height: 12),
        Text(_message),
        Text(
          _running && _endsAt != null
              ? '남은 시간: ${((_endsAt!.difference(DateTime.now()).inMilliseconds + 999) ~/ 1000).clamp(0, _scanDuration.inSeconds)}초'
              : '비콘 스캔 대기',
        ),
        const SizedBox(height: 12),
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
              onPressed: _running || _busy || _stopping ? null : _start,
              child: const Text('15초 스캔'),
            ),
            FilledButton.tonal(
              onPressed: _running || _busy || _stopping
                  ? null
                  : () => _start(duration: const Duration(seconds: 60)),
              child: const Text('60초 스캔'),
            ),
            OutlinedButton(
              onPressed: _running
                  ? () => unawaited(_stop('사용자가 스캔을 중지했습니다.'))
                  : null,
              child: const Text('중지'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            const Text('간격 조절 기준: '),
            DropdownButton<String>(
              value: _toneBeaconMac,
              items: const [
                DropdownMenuItem(value: beaconA, child: Text('비콘 A (…47)')),
                DropdownMenuItem(value: beaconB, child: Text('비콘 B (…48)')),
              ],
              onChanged: (value) {
                if (value != null) setState(() => _toneBeaconMac = value);
              },
            ),
          ],
        ),
        WitSensorPanel(
          key: const ValueKey('wit-sensor-panel'),
          ensureReady: _ready,
          beaconRssi: _signals[_toneBeaconMac]?.rssi,
          beaconSeenAt: _radioTimes[_toneBeaconMac],
          beaconName: _toneBeaconMac == beaconA ? 'A (…47)' : 'B (…48)',
        ),
        _card('A', beaconA),
        _card('B', beaconB),
        Text('이번 스캔에서 확인한 기기: ${_signals.length}개'),
        const SizedBox(height: 12),
        const Text(
          '두 비콘의 이름/UUID가 같아 MAC으로 구분합니다. RSSI는 기존 패키지의 보정값이며 정확한 거리나 차량 확인을 뜻하지 않습니다. 방향음의 목표는 직접 지정한 기준각이며 비콘 방향은 추정하지 않습니다. 서버 전송은 포함하지 않습니다.',
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
