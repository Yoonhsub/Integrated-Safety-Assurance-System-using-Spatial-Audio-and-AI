import 'dart:async';
import 'package:flutter/material.dart';
import '../services/speech_priority_coordinator.dart';
import '../services/vision_observation_speech.dart';

/// Observation text and optional low-priority speech; never mutates guidance.
class VisionObservationPanel extends StatefulWidget {
  const VisionObservationPanel({
    super.key,
    required this.sessionId,
    required this.fetch,
    this.ownerUid,
    this.authChanges,
    this.speechPriority,
    this.speechClock,
    this.scopeVersion,
    this.priorityBlocked = false,
  });
  final String sessionId;
  final Future<Map<String, dynamic>> Function(String) fetch;
  final String? ownerUid;
  final Stream<String?>? authChanges;
  final SpeechPriorityCoordinator? speechPriority;
  final int Function()? speechClock;
  final Object? scopeVersion;
  final bool priorityBlocked;

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
      if (uid != widget.ownerUid) _invalidateAuth();
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
    _allowed = widget.authChanges == null || widget.ownerUid != null;
    _priority = widget.speechPriority ?? sharedSpeechPriority;
    _speech = VisionObservationSpeech(_priority, nowMicros: widget.speechClock)
      ..setScope(widget.ownerUid, widget.sessionId, widget.scopeVersion);
    _speech.addListener(_speechChanged);
    _subscribeAuth();
    _poll();
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
      _allowed = widget.authChanges == null || widget.ownerUid != null;
      _poll();
    }
    if (oldWidget.authChanges != widget.authChanges) _subscribeAuth();
    _setBlocked(
        widget.priorityBlocked || !(ModalRoute.of(context)?.isCurrent ?? true));
  }

  Future<void> _poll() async {
    if (!_allowed || _inFlight || widget.sessionId.isEmpty) return;
    _inFlight = true;
    final generation = _generation;
    final request = Stopwatch()..start();
    try {
      final data = await widget.fetch(widget.sessionId);
      if (!mounted || generation != _generation) return;
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
    } catch (_) {
      if (mounted && generation == _generation) {
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
            SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Vision 음성 안내'),
                value: _speech.enabled,
                onChanged: _allowed && widget.ownerUid != null
                    ? _speech.setEnabled
                    : null),
            OutlinedButton(
                onPressed: _speech.enabled ? _speech.stop : null,
                child: const Text('Vision 음성 중지')),
            Text(_speech.status),
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
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(replay ? '녹화 영상 기반 시연 정보입니다' : '웹캠 입력 · 촬영 시각 미검증'),
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
        ],
      ),
    );
  }
}
