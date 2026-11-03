import 'dart:async';
import '../local_vision/vision_codec.dart';
import '../local_vision/frame_pump.dart';
import 'package:flutter/material.dart';
import '../services/speech_priority_coordinator.dart';
import '../services/vision_observation_speech.dart';
import '../services/v3_agent_api_client.dart';

/// Observation text and optional low-priority speech; never mutates guidance.
class VisionObservationPanel extends StatefulWidget {
  const VisionObservationPanel({
    super.key,
    required this.sessionId,
    required this.fetch,
    this.ownerUid,
    this.captureAuthGuard,
    this.authChanges,
    this.speechPriority,
    this.speechClock,
    this.scopeVersion,
    this.priorityBlocked = false,
    this.hideSpeechControls = false,
  });

  /// Read-only local preview, deliberately bypasses neither server ownership
  /// nor guidance eligibility: it never polls or constructs a speech engine.
  static Widget localCamera(LocalObservation observation) {
    final result = observation.toDetectionResult();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('로컬 DetectionResult · Schema 계약 검사 통과'),
      const Text('guidanceEligible=false · 방향/거리/승차 가능 여부 미확인'),
      Text('frameId: ${result['frameId']}'),
      Text(
          '입력 ${observation.frame.format} ${observation.frame.width}×${observation.frame.height} · 회전 ${observation.frame.rotation}° · mirror=${observation.frame.mirror}'),
      Text('보정 이미지 ${observation.width}×${observation.height}'),
      Text('프레임 수신 ${result['capturedAt']} · 센서 노출 시각 미검증'),
      Text(
          '추론 ${observation.inferenceMs.toStringAsFixed(1)}ms · 처리 ${observation.processingMs.toStringAsFixed(1)}ms'),
      if (observation.boxes.isEmpty) const Text('현재 검출 객체 없음 · 안전함을 의미하지 않음'),
      for (final b in observation.boxes)
        Text(
            '${b.classId == 'bus' ? '버스' : '버스 문'} · ${b.confidence.toStringAsFixed(3)} · bbox [${b.x.toStringAsFixed(3)}, ${b.y.toStringAsFixed(3)}, ${b.w.toStringAsFixed(3)}, ${b.h.toStringAsFixed(3)}]'),
    ]);
  }

  final String sessionId;
  final Future<Map<String, dynamic>> Function(String) fetch;
  final String? ownerUid;
  final bool Function() Function()? captureAuthGuard;
  final Stream<String?>? authChanges;
  final SpeechPriorityCoordinator? speechPriority;
  final int Function()? speechClock;
  final Object? scopeVersion;
  final bool priorityBlocked;
  final bool hideSpeechControls;

  @override
  State<VisionObservationPanel> createState() => _VisionObservationPanelState();
}

class _VisionObservationPanelState extends State<VisionObservationPanel> {
  Timer? _timer;
  List<Map<String, dynamic>> _items = [];
  Stopwatch _age = Stopwatch();
  double _requestSeconds = 0;
  bool _inFlight = false;
  int _generation = 0;
  StreamSubscription<String?>? _authSubscription;
  bool _allowed = true;
  bool Function()? _authGuard;
  late final VisionObservationSpeech _speech;
  late final SpeechPriorityCoordinator _priority;
  PriorityLease? _externalLease;
  int _authGeneration = 0, _blockGeneration = 0;
  bool _blocked = false;
  void _speechChanged() {
    if (mounted) setState(() {});
  }

  void _setBlocked(bool value) {
    if (_blocked == value) return;
    _blocked = value;
    final generation = ++_blockGeneration;
    if (!value) {
      _externalLease?.release();
      _externalLease = null;
      return;
    }
    unawaited(_priority.acquirePriority().then((lease) {
      if (!mounted || generation != _blockGeneration) {
        lease.release();
      } else {
        _externalLease = lease;
      }
    }));
  }

  void _subscribeAuth() {
    _authSubscription?.cancel();
    final generation = ++_authGeneration;
    _authSubscription = widget.authChanges?.listen((uid) {
      if (generation != _authGeneration || !mounted) return;
      if (uid != widget.ownerUid || !(_authGuard?.call() ?? true)) {
        _invalidateAuth();
      }
    }, onError: (Object _) {
      if (generation == _authGeneration && mounted) _invalidateAuth();
    });
  }

  void _invalidateAuth() {
    _generation++;
    _speech.setScope(null, '', null);
    setState(() {
      _allowed = false;
      _items = [];
    });
  }

  @override
  void initState() {
    super.initState();
    _authGuard = widget.captureAuthGuard?.call();
    _allowed = (widget.authChanges == null || widget.ownerUid != null) &&
        (_authGuard?.call() ?? true);
    _priority = widget.speechPriority ?? sharedSpeechPriority;
    _speech = VisionObservationSpeech(_priority, nowMicros: widget.speechClock)
      ..setScope(widget.ownerUid, widget.sessionId, widget.scopeVersion);
    _speech.addListener(_speechChanged);
    _subscribeAuth();
    _poll();
    _startPolling();
  }

  void _startPolling() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
      _poll();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _setBlocked(
        widget.priorityBlocked || !(ModalRoute.of(context)?.isCurrent ?? true));
  }

  @override
  void didUpdateWidget(covariant VisionObservationPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionId != widget.sessionId ||
        oldWidget.ownerUid != widget.ownerUid ||
        oldWidget.scopeVersion != widget.scopeVersion) {
      _generation++;
      _speech.setScope(widget.ownerUid, widget.sessionId, widget.scopeVersion);
      _items = [];
      _inFlight = false;
      _allowed = (widget.authChanges == null || widget.ownerUid != null) &&
          (_authGuard?.call() ?? true);
      if (_allowed) _startPolling();
      _poll();
    }
    if (oldWidget.authChanges != widget.authChanges) _subscribeAuth();
    _setBlocked(
        widget.priorityBlocked || !(ModalRoute.of(context)?.isCurrent ?? true));
  }

  Future<void> _poll() async {
    if (!(_authGuard?.call() ?? true)) {
      if (_allowed) _invalidateAuth();
      return;
    }
    if (!_allowed || _inFlight || widget.sessionId.isEmpty) return;
    _inFlight = true;
    final generation = _generation;
    final request = Stopwatch()..start();
    try {
      final data = await widget.fetch(widget.sessionId);
      if (!mounted ||
          generation != _generation ||
          !(_authGuard?.call() ?? true)) {
        return;
      }
      if (data['sessionId'] != widget.sessionId ||
          data['observations'] is! List) {
        throw const FormatException('Invalid observation scope');
      }
      final items = (data['observations'] as List)
          .map((item) => Map<String, dynamic>.from(item as Map))
          .toList();
      _speech.update(items, request.elapsed);
      setState(() {
        _items = items;
        _requestSeconds = request.elapsedMicroseconds / 1000000;
        _age = Stopwatch()..start();
      });
    } catch (error) {
      if (mounted && generation == _generation) {
        if (error is VisionLeaseException && error.terminal) {
          _invalidateAuth();
          _timer?.cancel();
        }
        _speech.clear();
        setState(() => _items = []);
      }
    } finally {
      if (generation == _generation) _inFlight = false;
    }
  }

  @override
  void dispose() {
    _generation++;
    _authGeneration++;
    _blockGeneration++;
    _speech.removeListener(_speechChanged);
    _speech.dispose();
    _externalLease?.release();
    _timer?.cancel();
    _authSubscription?.cancel();
    _age.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'AI Vision 관찰',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const Text('승차 판단과 분리된 관찰 정보입니다.'),
            if (!widget.hideSpeechControls)
              SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Vision 음성 안내'),
                  value: _speech.enabled,
                  onChanged: _allowed && widget.ownerUid != null
                      ? _speech.setEnabled
                      : null),
            if (!widget.hideSpeechControls)
              OutlinedButton(
                  onPressed: _speech.enabled ? _speech.stop : null,
                  child: const Text('Vision 음성 중지')),
            if (!widget.hideSpeechControls) Text(_speech.status),
            if (_items.isEmpty) const Text('현재 관찰 정보가 없습니다'),
            for (final item in _items) _observation(item),
          ],
        ),
      ),
    );
  }

  Widget _observation(Map<String, dynamic> item) {
    final ttl = item['validForSeconds'];
    final available = item['state'] == 'available' &&
        ttl is num &&
        ttl.isFinite &&
        ttl > _requestSeconds + _age.elapsedMicroseconds / 1000000;
    final classes = item['observedClasses'];
    final bus = available && classes is List && classes.contains('bus');
    final door = available && classes is List && classes.contains('bus_door');
    final replay = item['sourceType'] == 'replay';
    final android = item['sourceType'] == 'android_camera';
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(replay
              ? '녹화 영상 기반 시연 정보입니다'
              : android
                  ? 'Android 카메라 형식 입력 · 촬영 시각 미검증'
                  : '웹캠 입력 · 촬영 시각 미검증'),
          Text(
            item['state'] == 'lost'
                ? '카메라 연결이 중단되었습니다'
                : !available
                    ? '현재 관찰 정보가 없습니다'
                    : bus && door
                        ? '버스와 버스 문이 감지되었습니다'
                        : door
                            ? '버스 문이 감지되었습니다'
                            : bus
                                ? '버스가 감지되었습니다'
                                : '현재 관찰된 대상 객체가 없습니다',
          ),
          if (available) Text('서버 수신 시각: ${item['receivedAt'] ?? '-'}'),
          if (available) ...[
            Text('frameId: ${item['frameId'] ?? '-'}'),
            Text('프레임 시각: ${item['capturedAt'] ?? '-'}'),
            Text('이미지 크기: ${item['imageSize'] ?? '-'} · 정규화된 회전 보정 bbox'),
            for (final detection in (item['detections'] as List? ?? const []))
              Text(
                  '${detection['className']} (${detection['classId']}) · confidence ${detection['confidence']} · bbox ${detection['bbox']}'),
          ],
        ],
      ),
    );
  }
}

/// Shared start/stop surface: displayed observations are fetched from Backend,
/// never copied from the local inference result. Input ownership is explicit.
class VisionPreviewPage extends StatefulWidget {
  const VisionPreviewPage(
      {super.key,
      required this.pump,
      required this.producer,
      required this.api,
      required this.ownerUid,
      required this.inputLabel,
      required this.startFrames,
      required this.stopFrames,
      this.endSession});
  final FramePump pump;
  final DartVisionProducerClient producer;
  final V3AgentApiClient api;
  final String ownerUid, inputLabel;
  final Future<void> Function(void Function(VisionFrame)) startFrames;
  final Future<void> Function() stopFrames;
  final Future<void> Function()? endSession;
  @override
  State<VisionPreviewPage> createState() => _VisionPreviewPageState();
}

class _VisionPreviewPageState extends State<VisionPreviewPage> {
  bool _busy = false, _ended = false, _disposed = false;
  int _scope = 0;
  String _status = 'Vision을 시작해 주세요';
  void _changed() {
    if (!mounted) return;
    if (widget.pump.error != null) unawaited(widget.stopFrames());
    setState(() {});
  }

  @override
  void initState() {
    super.initState();
    widget.pump.addListener(_changed);
  }

  Future<void> _start() async {
    if (_busy || _ended || _disposed) return;
    setState(() {
      _busy = true;
      _status = 'Vision 준비 중';
    });
    final scope = ++_scope;
    try {
      await widget.producer.retryPending(discardExpired: true);
      if (!mounted || scope != _scope || _ended) return;
      widget.pump.start();
      await widget.startFrames(widget.pump.submit);
      if (mounted && scope == _scope) {
        setState(() => _status = 'Vision 입력 → Backend 전송 → Passenger 조회 중');
      }
    } catch (e) {
      await widget.stopFrames();
      await widget.pump.stop();
      if (mounted && scope == _scope) {
        setState(() => _status =
            e is VisionProducerException ? e.message : 'Vision을 시작할 수 없습니다.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _stop({bool end = false}) async {
    if (_busy || _disposed) return;
    ++_scope;
    setState(() {
      _busy = true;
      if (end) _ended = true;
      _status = end ? '세션 종료 중' : 'Vision 중단 중';
    });
    widget.producer.cancel();
    final idle = widget.pump.stop();
    try {
      await widget.stopFrames();
      await idle;
      if (end) await widget.endSession?.call();
      if (mounted) {
        setState(
            () => _status = end ? '세션 종료 · 이전 결과 폐기' : 'Vision 중단 · 표시 결과 폐기');
      }
    } catch (_) {
      if (mounted) setState(() => _status = '종료 결과를 확인해 주세요. 화면과 전송은 중단되었습니다.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    ++_scope;
    widget.pump.removeListener(_changed);
    widget.producer.close();
    unawaited(widget.stopFrames());
    unawaited(widget.pump.stop());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('Passenger Vision Preview')),
      body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(widget.inputLabel),
            const Text(
                'Preview only · guidanceEligible=false · Safety Event / 음향 출력 없음'),
            Wrap(spacing: 12, children: [
              ElevatedButton(
                  onPressed:
                      _busy || _ended || widget.pump.active ? null : _start,
                  child: const Text('Vision 시작 / 복구')),
              OutlinedButton(
                  onPressed: _busy || _ended ? null : () => _stop(),
                  child: const Text('Vision 중단')),
              OutlinedButton(
                  onPressed: _busy || _ended ? null : () => _stop(end: true),
                  child: const Text('세션 종료')),
            ]),
            Text(_status),
            Text(
                '프레임 수신 ${widget.pump.received} · 처리 ${widget.pump.processed} · 전송 확인 ${widget.producer.submitted}'),
            if (widget.pump.error != null)
              Text(widget.pump.error!,
                  style: const TextStyle(color: Colors.red)),
            if (!_ended &&
                widget.pump.active &&
                widget.pump.error == null &&
                widget.pump.processed > 0)
              VisionObservationPanel(
                  key: ValueKey(_scope),
                  sessionId: widget.producer.sessionId,
                  ownerUid: widget.ownerUid,
                  fetch: widget.api.fetchVisionObservations,
                  hideSpeechControls: true),
          ])));
}
