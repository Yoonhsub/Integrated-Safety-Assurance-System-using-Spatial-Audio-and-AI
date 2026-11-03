import 'dart:async';
import 'package:flutter/material.dart';
import 'package:mobi_mobile_sensors/mobi_mobile_sensors.dart';
import '../services/session_guidance_audio.dart';
import '../services/local_demo_beacon_mapping.dart';
import '../services/speech_priority_coordinator.dart';

// Reuse one scanner: a previous page's delayed stop cannot start a second scan.
final _passengerBeaconScanner = FlutterBlueBeaconScanner();

/// App wiring only. The sensor package owns BLE and the existing audio
/// coordinator owns playback. An advertisement is never a vehicle registry.
class GuidanceBeaconPanel extends StatefulWidget {
  const GuidanceBeaconPanel(
      {super.key,
      required this.sessionId,
      required this.scopeVersion,
      required this.ownerUid,
      required this.targetBusId,
      required this.routeNo,
      required this.priority,
      required this.captureGuard,
      required this.captureAudioGuard,
      required this.authChanges,
      this.scanner,
      this.mockInput = false,
      this.identities = const [],
      this.demoMapping = const LocalDemoBeaconMapping.disabled(),
      this.clock});
  final LocalDemoBeaconMapping demoMapping;
  final DateTime Function()? clock;
  final String sessionId, ownerUid;
  final int scopeVersion;
  final String? targetBusId, routeNo;
  final SpeechPriorityCoordinator priority;
  final bool Function() Function() captureGuard, captureAudioGuard;
  final Stream<Object?> authChanges;
  final BeaconScanner? scanner;
  // No production registry exists yet. Only explicit local fixtures populate it.
  final bool mockInput;
  final List<BeaconIngestIdentity> identities;
  @override
  State<GuidanceBeaconPanel> createState() => _GuidanceBeaconPanelState();
}

class _GuidanceBeaconPanelState extends State<GuidanceBeaconPanel>
    with WidgetsBindingObserver {
  late final BeaconScanner _scanner;
  StreamSubscription<BeaconSignal>? _signals;
  StreamSubscription<Object?>? _auth;
  Future<void>? _stopping;
  final _owner = Object();
  final _clock = Stopwatch()..start();
  final _announced = <String>{};
  final _seen = <String>{};
  final _watermarks = <String, DateTime>{};
  Timer? _loss;
  DateTime? _matchedAt;
  bool _running = false, _matched = false, _disposed = false;
  int _revision = 0;
  String _status = 'BLE 미감지 · 스캔을 시작해 주세요';
  String? _audioError, _lastBeaconId;
  int? _lastRssi;
  late bool Function() _guard;
  DateTime _now() => widget.clock?.call() ?? DateTime.now();

  @override
  void initState() {
    super.initState();
    _scanner = widget.scanner ?? _passengerBeaconScanner;
    _guard = widget.captureGuard();
    WidgetsBinding.instance.addObserver(this);
    _auth = widget.authChanges.listen((_) {
      if (!_guard()) unawaited(_stop('로그아웃 · BLE 종료'));
    }, onError: (Object _) => unawaited(_stop('인증 상태 확인 불가 · BLE 종료')));
  }

  @override
  void didUpdateWidget(covariant GuidanceBeaconPanel old) {
    super.didUpdateWidget(old);
    if (old.sessionId != widget.sessionId ||
        old.scopeVersion != widget.scopeVersion ||
        old.ownerUid != widget.ownerUid ||
        old.targetBusId != widget.targetBusId ||
        old.routeNo != widget.routeNo) {
      _announced.clear();
      _guard = widget.captureGuard();
      unawaited(_stop('목표 또는 세션 변경 · 다시 스캔해 주세요'));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) unawaited(_stop('백그라운드 · BLE 종료'));
  }

  Future<void> _start() async {
    if (_running || _stopping != null || !_guard() || _disposed) return;
    final ticket = ++_revision;
    _loss?.cancel();
    _lastBeaconId = null;
    _lastRssi = null;
    _seen.clear();
    _watermarks.clear();
    _matchedAt = null;
    _matched = false;
    setState(() {
      _running = true;
      _status = 'BLE 스캔 중 · 아직 미감지';
    });
    _loss = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_matchedAt != null &&
          _now().difference(_matchedAt!) >= const Duration(seconds: 5)) {
        _matchedAt = null;
        if (mounted) {
          setState(() {
            _matched = false;
            _status = '목표 비콘 신호 소실 · 현재 식별되지 않음';
          });
        }
      }
    });
    try {
      _signals = _scanner.scan().listen((signal) => _receive(signal, ticket),
          onError: (Object error) {
        if (_disposed || ticket != _revision) return;
        debugPrint('Guidance BLE scan failure: ${error.runtimeType}');
        unawaited(_stop('BLE 스캔 실패 · 근처 기기 권한과 Bluetooth 상태를 확인해 주세요'));
      }, onDone: () {
        if (_disposed || ticket != _revision) return;
        _signals = null;
        if (_matchedAt == null) _loss?.cancel();
        if (mounted && ticket == _revision) {
          setState(() {
            _running = false;
            _status = _matched ? '스캔 완료 · 마지막 신호 표시 중' : '스캔 완료 · 목표 버스 미확인';
          });
        }
      });
    } catch (error) {
      debugPrint('Guidance BLE start failure: ${error.runtimeType}');
      await _stop('BLE 시작 실패 · Bluetooth와 권한을 확인해 주세요');
    }
  }

  void _receive(BeaconSignal signal, int ticket) {
    if (_disposed ||
        !mounted ||
        !_running ||
        ticket != _revision ||
        !_guard()) {
      return;
    }
    final now = _now();
    final age = now.difference(signal.lastDetectedAt);
    final previous = _watermarks[signal.beaconId];
    if (age.isNegative ||
        age >= const Duration(seconds: 5) ||
        (previous != null && !signal.lastDetectedAt.isAfter(previous))) {
      return;
    }
    _watermarks[signal.beaconId] = signal.lastDetectedAt;
    if (_watermarks.length > 128) _watermarks.remove(_watermarks.keys.first);
    if (_seen.length < 128) _seen.add(signal.beaconId);
    // Only an explicit local configuration can associate a real device address
    // with a demonstration bus. This is not an operating vehicle registration.
    final identities = widget.mockInput
        ? widget.identities
            .where((identity) =>
                BeaconScannerFilters.matchesTarget(signal, identity.beaconId))
            .toList()
        : widget.demoMapping.find(signal.beaconId);
    final identity = identities.length == 1 ? identities.single : null;
    final matches = !signal.isLost &&
        identity != null &&
        widget.targetBusId != null &&
        identity.busId == widget.targetBusId &&
        (widget.routeNo == null || identity.routeNo == widget.routeNo);
    setState(() {
      _lastBeaconId = signal.beaconId;
      _lastRssi = signal.rssi;
      if (matches) {
        _matched = true;
        _matchedAt = signal.lastDetectedAt;
        _status = widget.mockInput
            ? '테스트 입력 · 목표 버스 비콘 일치'
            : '로컬 시연 매핑 · 목표 버스 비콘 일치 · 운행 차량 등록 아님';
      } else if (!_matched) {
        _status = widget.targetBusId == null
            ? 'BLE 수신 · 목표 버스 미선택'
            : widget.mockInput
                ? 'BLE 수신 · 목표 버스와 일치하지 않음'
                : widget.demoMapping.enabled
                    ? (identity == null
                        ? '미등록 비콘 수신 · 목표 버스 미확인'
                        : '시연 매핑 · 다른 버스 비콘 수신')
                    : 'BLE 수신 · 실제 비콘-버스 매핑 미등록 · 목표 버스 미확인';
      }
    });
    final key =
        '${widget.sessionId}/${widget.scopeVersion}/${widget.targetBusId}';
    if (!matches || age >= const Duration(seconds: 3) || !_announced.add(key)) {
      return;
    }
    final guard = widget.captureAudioGuard();
    final revision = _revision;
    final admission = ObservationAdmission(
        deadlineMicros: _clock.elapsedMicroseconds +
            const Duration(seconds: 3).inMicroseconds -
            age.inMicroseconds,
        nowMicros: () => _clock.elapsedMicroseconds,
        eventId: 'ble:$key',
        sessionGeneration: '${widget.scopeVersion}',
        receivedAt: now.toUtc().toIso8601String(),
        eventCreatedAt: signal.lastDetectedAt.toUtc().toIso8601String());
    unawaited(SessionGuidanceAudio(priority: widget.priority)
        .speak(
            _owner,
            SessionGuidanceObservation(
                sessionId: widget.sessionId,
                ownerUid: widget.ownerUid,
                generation: '${widget.scopeVersion}',
                eventId: 'ble:$key',
                synthetic: true,
                text:
                    '${widget.mockInput ? '테스트 입력입니다.' : '로컬 시연 매핑 기준입니다. 실제 운행 차량 등록 정보는 아닙니다.'} 선택한 ${widget.routeNo ?? ''}번 버스의 비콘 신호가 일치합니다. 승차 가능 여부와 출입문 방향은 확인되지 않았습니다.'),
            () => !_disposed && revision == _revision && _guard() && guard(),
            admission: admission)
        .catchError((Object error) {
      debugPrint('Guidance BLE audio failure: ${error.runtimeType}');
      if (mounted && revision == _revision) {
        setState(() => _audioError = '비콘 정보 음성을 재생하지 못했습니다.');
      }
      return false;
    }));
  }

  Future<void> _stop(String reason) {
    final ownsScan = _running || _signals != null;
    _revision++;
    _running = false;
    _matched = false;
    _matchedAt = null;
    _lastBeaconId = null;
    _lastRssi = null;
    _seen.clear();
    _loss?.cancel();
    _loss = null;
    final subscription = _signals;
    _signals = null;
    if (mounted && !_disposed) setState(() => _status = reason);
    final pending = _stopping;
    if (pending != null) return pending;
    final operation = Future.wait<void>([
      // Stop the producer before cancelling its async-generator consumer.
      if (ownsScan) _scanner.stop(),
      Future<void>.sync(() async {
        await subscription?.cancel();
      }),
      widget.priority.stopObservation(_owner),
    ]).then<void>((_) {});
    _stopping = operation;
    return operation.then<void>((_) {
      if (identical(_stopping, operation)) {
        _stopping = null;
        if (mounted && !_disposed) setState(() {});
      }
    }, onError: (Object error) {
      // Keep the start barrier closed when actual scanner shutdown is unknown.
      debugPrint('Guidance BLE cleanup failure: ${error.runtimeType}');
      if (mounted && !_disposed) {
        setState(() => _status = 'BLE 종료 확인 불가 · 앱을 다시 열어 주세요');
      }
    });
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_auth?.cancel());
    unawaited(_stop('페이지 종료'));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Card(
      child: Padding(
          padding: const EdgeInsets.all(12),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('BLE 목표 버스 확인'),
            Text(
                '목표 버스: ${widget.targetBusId ?? '미선택'} · 노선: ${widget.routeNo ?? '-'}'),
            Text(widget.mockInput
                ? '명시적 Mock BLE 입력 · 실제 비콘 검증 아님'
                : widget.demoMapping.enabled
                    ? '실제 BLE 스캔 + 로컬 시연 매핑 ${widget.demoMapping.identities.length}건 · 운행 차량 등록 아님'
                    : '실제 BLE 스캔 · 비콘-버스 등록 정보 없음'),
            if (widget.demoMapping.issue != null)
              Text(widget.demoMapping.issue!),
            Text(_status),
            Text('수신 기기 수: ${_seen.length}'),
            if (_lastBeaconId != null)
              ExpansionTile(title: const Text('수신 식별값 확인'), children: [
                Text('Android remoteId: $_lastBeaconId · RSSI: $_lastRssi dBm'),
                const Text('광고 이름으로 버스를 식별하지 않습니다.'),
              ]),
            const Text('BLE 수신만으로 승차 가능 여부·방향·거리를 판단하지 않습니다.'),
            if (_audioError != null) Text(_audioError!),
            Wrap(spacing: 8, children: [
              OutlinedButton(
                  onPressed: !_running && _stopping == null && _guard()
                      ? _start
                      : null,
                  child: const Text('BLE 스캔 시작')),
              OutlinedButton(
                  onPressed: _running ? () => _stop('사용자 중지 · BLE 미감지') : null,
                  child: const Text('BLE 스캔 중지')),
            ])
          ])));
}
