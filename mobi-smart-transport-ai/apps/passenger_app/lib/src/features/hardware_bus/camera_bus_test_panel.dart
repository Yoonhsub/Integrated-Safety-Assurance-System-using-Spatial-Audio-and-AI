import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../local_vision/native_local_vision_page.dart';
import '../../local_vision/vision_codec.dart';
import '../../services/head_tracking_direction.dart';
import 'camera_bus_target.dart';
import 'direction_audio_panel.dart';
import 'wit_sensor_panel.dart';

class CameraBusTestPanel extends StatefulWidget {
  const CameraBusTestPanel(
      {super.key,
      required this.ensureReady,
      required this.rssi,
      required this.seenAt,
      required this.beaconName,
      required this.scope});
  final Future<bool> Function() ensureReady;
  final int? rssi;
  final DateTime? seenAt;
  final String beaconName, scope;
  @override
  State<CameraBusTestPanel> createState() => _CameraBusTestPanelState();
}

class _CameraBusTestPanelState extends State<CameraBusTestPanel>
    with WidgetsBindingObserver {
  static const _headingChannel = EventChannel('mobi/phone_camera_heading');
  final _tracker = CameraBusTargetTracker();
  StreamSubscription<dynamic>? _heading;
  Timer? _timer;
  bool _associated = false, _disposed = false;
  double? _reference;
  String _phoneStatus = '휴대폰 방향 자동 측정 준비 중';
  Future<void> _headingStopping = Future<void>.value();
  double? _phoneDegrees;
  int _session = 0;
  final _fov = TextEditingController(text: '60');
  HeadTrackingSnapshot get _head => sharedHeadTrackingState.snapshot;
  bool _beaconFresh(DateTime now) =>
      widget.rssi != null &&
      widget.seenAt != null &&
      !now.difference(widget.seenAt!).isNegative &&
      now.difference(widget.seenAt!) < const Duration(seconds: 3);
  void _refresh() {
    if (mounted && !_disposed) setState(() {});
  }

  void _headChanged() {
    if (_tracker.calibrated &&
        (_head.referenceYaw != _reference ||
            _head.status != HeadTrackingStatus.ready)) {
      _tracker.reset();
    }
    _refresh();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    sharedHeadTrackingState.addListener(_headChanged);
    _timer =
        Timer.periodic(const Duration(milliseconds: 100), (_) => _refresh());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_disposed) unawaited(_startHeading());
    });
  }

  Future<void> _startHeading() async {
    final generation = ++_session;
    _tracker.reset();
    await _headingStopping;
    await _heading?.cancel();
    if (_disposed || generation != _session) return;
    _heading = _headingChannel.receiveBroadcastStream().listen((dynamic value) {
      if (_disposed || generation != _session) return;
      try {
        final sample = CameraHeadingSample(
            (value['heading'] as num).toDouble(),
            DateTime.fromMillisecondsSinceEpoch(value['receivedAtMs'] as int,
                isUtc: true),
            usable: value['usable'] == true);
        _tracker.addPhone(sample);
        _phoneDegrees = sample.degrees;
        _phoneStatus =
            sample.usable ? '휴대폰 방향 수신 중' : '휴대폰을 세워 정면을 비추고 방향 센서를 보정하세요';
        if (!sample.usable) _tracker.clear('휴대폰 방향 신뢰도 부족');
      } catch (_) {
        _tracker.reset();
        _phoneStatus = '휴대폰 방향 데이터 오류';
      }
      _refresh();
    }, onError: (Object e) {
      _tracker.reset();
      _phoneStatus = '휴대폰 방향 사용 불가';
      _refresh();
    }, onDone: () {
      _tracker.reset();
      _refresh();
    });
    _refresh();
  }

  void _calibrate() {
    final now = DateTime.now().toUtc();
    final fov = double.tryParse(_fov.text);
    if (!_associated ||
        !_head.usable(now, maximumAge: const Duration(seconds: 1)) ||
        fov == null ||
        fov < 20 ||
        fov > 130) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('단일 대상 확인·센서 정면 설정·화각 20~130° 입력이 필요합니다.')));
      return;
    }
    _tracker.fov = fov;
    _reference = _head.referenceYaw;
    if (!_tracker.calibrate(_head.filteredYaw!, now)) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('최신 휴대폰 방향을 수신한 뒤 다시 설정하세요.')));
    }
    _refresh();
  }

  Future<void> _observe(LocalObservation value) async {
    if (_disposed) return;
    if (_associated && _tracker.calibrated) {
      _tracker.observe(value, DateTime.now().toUtc());
    } else {
      _tracker.clear('동일 정면 설정·시험 대상 연결 확인 필요');
    }
    debugPrint(
        'MOBI_TRIPLE frame=${value.frame.frameId} rssi=${widget.rssi} phone=$_phoneDegrees head=${_head.filteredYaw} status=${_tracker.reason}');
    _refresh();
  }

  Future<void> _cameraStopped() async {
    _tracker.clear('카메라 중지 · 방향 안내 중지');
    _refresh();
  }

  @override
  void didUpdateWidget(covariant CameraBusTestPanel old) {
    super.didUpdateWidget(old);
    if (old.scope != widget.scope) {
      _tracker.reset();
      _associated = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _tracker.reset();
      _session++;
      _headingStopping = Future.wait<void>([
        _headingStopping,
        if (_heading != null) _heading!.cancel(),
      ]).then((_) {});
      _heading = null;
      _phoneStatus = '화면 비활성화 · 휴대폰 방향 측정 중지';
      _refresh();
    } else if (!_disposed) {
      unawaited(_startHeading());
    }
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now().toUtc(), head = _head;
    final fresh = head.usable(now, maximumAge: const Duration(seconds: 1));
    final age = head.age(now)?.inMilliseconds ?? 99999;
    final angle = _associated
        ? _tracker.angle(now,
            headYaw: head.filteredYaw,
            headFresh: fresh,
            beaconFresh: _beaconFresh(now))
        : null;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('카메라·머리 센서·비콘 통합 방향 시험',
          style: TextStyle(fontWeight: FontWeight.bold)),
      const Text(
          '머리: WT901 / 손: 후면 카메라. 통제된 장소의 단일 버스·단일 문만 시험합니다. 실측 카메라·센서·BLE, 목표 연결은 수동입니다. 실제 탑승 안내가 아닙니다.'),
      WitSensorPanel(stateOnly: true, ensureReady: widget.ensureReady),
      Text('$_phoneStatus · ${_phoneDegrees?.toStringAsFixed(1) ?? "-"}°'),
      TextField(
          controller: _fov,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
              labelText: '현재 영상 수평 화각(°) · 기본 60은 시험용 가정값'),
          onChanged: (_) {
            _tracker.reset();
            _refresh();
          }),
      CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          title: Text('화면의 단일 버스 문을 ${widget.beaconName} 시험 대상으로 연결'),
          subtitle: const Text('자동 차량 인증 아님 · 다른 버스가 들어오면 중지 후 다시 확인'),
          value: _associated,
          onChanged: (v) {
            setState(() {
              _associated = v == true;
              _tracker.reset();
            });
          }),
      SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('머리 센서 회전 부호 반대로'),
          subtitle: const Text('정면 재설정 후 실제 좌우 회전으로 확인'),
          value: _tracker.reverseHead,
          onChanged: (v) {
            setState(() {
              _tracker.reverseHead = v;
              _tracker.reset();
            });
          }),
      const Text(
          '머리와 카메라를 같은 정면 표식에 맞추세요. WT901 정면 설정 후 아래 기준을 설정합니다. 설정 중에는 휴대폰을 세우고 수평 방향을 유지하세요.'),
      FilledButton(onPressed: _calibrate, child: const Text('머리·카메라 동일 정면 설정')),
      Text(
          '방향 상태: ${angle == null ? "중지 · ${_tracker.reason}" : "문 상대각 ${angle.toStringAsFixed(1)}°"}'),
      const Text(
          '기본 화각은 근사값이므로 각도 정확도 검증이 아닙니다. 문·휴대폰 방향·머리 센서·목표 비콘 중 하나라도 오래되면 재생을 중지하며 수동 재시작이 필요합니다.'),
      DirectionAudioPanel(
          z: head.filteredYaw,
          reference: head.referenceYaw,
          fresh: fresh,
          sensorAgeMs: age,
          beaconRssi: widget.rssi,
          beaconSeenAt: widget.seenAt,
          beaconName: widget.beaconName,
          busAngle: angle ?? 0,
          busEnabled: angle != null,
          audioScope: '${widget.scope}/$_reference',
          targetIsHeadRelative: true),
      const SizedBox(height: 12),
      const Text('후면 카메라 · 통합 v4 실측'),
      SizedBox(
          height: 650,
          child: LocalVisionPage(
              bundledModel: true,
              localConsumer: true,
              onResult: _observe,
              onStop: _cameraStopped)),
    ]);
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    sharedHeadTrackingState.removeListener(_headChanged);
    _timer?.cancel();
    unawaited(_heading?.cancel());
    _fov.dispose();
    super.dispose();
  }
}
