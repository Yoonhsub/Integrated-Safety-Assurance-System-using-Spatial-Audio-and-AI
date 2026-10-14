import 'dart:async';
import 'package:flutter/material.dart';

/// Display only: no guidance mutation, voice or spatial audio dependency.
class VisionObservationPanel extends StatefulWidget {
  const VisionObservationPanel({
    super.key,
    required this.sessionId,
    required this.fetch,
    this.ownerUid,
    this.authChanges,
  });
  final String sessionId;
  final Future<Map<String, dynamic>> Function(String) fetch;
  final String? ownerUid;
  final Stream<String?>? authChanges;

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

  @override
  void initState() {
    super.initState();
    _allowed = widget.authChanges == null || widget.ownerUid != null;
    _authSubscription = widget.authChanges?.listen(
      (uid) {
        if (uid != widget.ownerUid && mounted) {
          _generation++;
          setState(() {
            _allowed = false;
            _items = [];
          });
        }
      },
      onError: (Object _) {
        if (mounted) {
          _generation++;
          setState(() {
            _allowed = false;
            _items = [];
          });
        }
      },
    );
    _poll();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {}); // Clear expired data even if HTTP is pending.
      }
      _poll();
    });
  }

  @override
  void didUpdateWidget(covariant VisionObservationPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionId != widget.sessionId ||
        oldWidget.ownerUid != widget.ownerUid) {
      _generation++;
      _items = [];
      _inFlight = false;
      _allowed = widget.authChanges == null || widget.ownerUid != null;
      _poll();
    }
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
      setState(() {
        _items = items;
        _requestSeconds = request.elapsedMicroseconds / 1000000;
        _age = Stopwatch()..start();
      });
    } catch (_) {
      if (mounted && generation == _generation) setState(() => _items = []);
    } finally {
      if (generation == _generation) _inFlight = false;
    }
  }

  @override
  void dispose() {
    _generation++;
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
            if (_items.isEmpty) const Text('현재 관찰 정보가 없습니다'),
            for (final item in _items) _observation(item),
          ],
        ),
      ),
    );
  }

  Widget _observation(Map<String, dynamic> item) {
    final ttl = item['validForSeconds'];
    final available =
        item['state'] == 'available' &&
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
