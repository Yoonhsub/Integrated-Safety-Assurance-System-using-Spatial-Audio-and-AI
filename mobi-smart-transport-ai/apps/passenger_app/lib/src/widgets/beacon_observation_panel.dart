import 'dart:async';
import 'package:flutter/material.dart';

/// Measurements only. This widget never selects a cue or changes guidance.
class BeaconObservationPanel extends StatefulWidget {
  const BeaconObservationPanel({
    super.key,
    required this.sessionId,
    required this.fetch,
    this.ownerUid,
    this.authChanges,
    this.scopeVersion,
  });

  final String sessionId;
  final Future<Map<String, dynamic>> Function(String) fetch;
  final String? ownerUid;
  final Stream<String?>? authChanges;
  final Object? scopeVersion;

  @override
  State<BeaconObservationPanel> createState() => _BeaconObservationPanelState();
}

class _BeaconObservationPanelState extends State<BeaconObservationPanel> {
  Timer? _timer;
  StreamSubscription<String?>? _subscription;
  List<Map<String, dynamic>> _items = [];
  Stopwatch _age = Stopwatch();
  double _requestSeconds = 0;
  bool _busy = false, _allowed = true;
  int _generation = 0, _authGeneration = 0;

  void _subscribeAuth() {
    _subscription?.cancel();
    final generation = ++_authGeneration;
    _subscription = widget.authChanges?.listen((uid) {
      if (!mounted || generation != _authGeneration) return;
      if (uid != widget.ownerUid) _invalidateAuth();
    }, onError: (Object _) {
      if (mounted && generation == _authGeneration) _invalidateAuth();
    });
  }

  void _invalidateAuth() {
    _generation++;
    setState(() {
      _allowed = false;
      _items = [];
    });
  }

  @override
  void initState() {
    super.initState();
    _allowed = widget.authChanges == null || widget.ownerUid != null;
    _subscribeAuth();
    _poll();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {}); // Age locally even when the next request is slow.
      if (ModalRoute.of(context)?.isCurrent ?? true) _poll();
    });
  }

  @override
  void didUpdateWidget(covariant BeaconObservationPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionId != widget.sessionId ||
        oldWidget.ownerUid != widget.ownerUid ||
        oldWidget.scopeVersion != widget.scopeVersion) {
      _generation++;
      _items = [];
      _busy = false;
      _allowed = widget.authChanges == null || widget.ownerUid != null;
      _poll();
    }
    if (oldWidget.authChanges != widget.authChanges ||
        oldWidget.ownerUid != widget.ownerUid) {
      _subscribeAuth();
    }
  }

  Future<void> _poll() async {
    if (!_allowed || _busy || widget.sessionId.isEmpty) return;
    _busy = true;
    final generation = _generation;
    final request = Stopwatch()..start();
    try {
      final data = await widget.fetch(widget.sessionId);
      if (!mounted || generation != _generation) return;
      if (data['sessionId'] != widget.sessionId ||
          data['guidanceEligible'] != false ||
          data['shouldSpeak'] != false ||
          data['shouldPlaySpatialCue'] != false ||
          data['observations'] is! List) {
        throw const FormatException('Invalid beacon observation scope');
      }
      final items = (data['observations'] as List)
          .map((item) => Map<String, dynamic>.from(item as Map))
          .toList();
      for (final item in items) {
        final ttl = item['validForSeconds'];
        if (item['vehicleIdentityVerified'] != false ||
            item['guidanceEligible'] != false ||
            item['beaconId'] is! String ||
            ttl is! num || !ttl.isFinite || ttl < 0) {
          throw const FormatException('Invalid beacon observation');
        }
      }
      setState(() {
        _items = items;
        _requestSeconds = request.elapsedMicroseconds / 1000000;
        _age = Stopwatch()..start();
      });
    } catch (_) {
      if (mounted && generation == _generation) setState(() => _items = []);
    } finally {
      if (generation == _generation) _busy = false;
    }
  }

  @override
  void dispose() {
    _generation++;
    _authGeneration++;
    _timer?.cancel();
    _subscription?.cancel();
    _age.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final elapsed = _requestSeconds + _age.elapsedMicroseconds / 1000000;
    final current = _items.where((item) =>
        (item['validForSeconds'] as num).toDouble() > elapsed).toList();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('BLE 수신 관찰',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const Text('차량 확인이나 승차 허용을 의미하지 않습니다.'),
            if (current.isEmpty) const Text('현재 비콘 수신 정보가 없습니다'),
            for (final item in current)
              Text('${item['beaconId']} · ${item['rssi']} dBm'
                  '${item['source'] == 'REAL_BLE' ? ' · BLE 입력' : ' · 테스트 입력'}'
                  '${item['mappingRegistered'] == true ? ' · 등록된 비콘' : ''}'),
          ],
        ),
      ),
    );
  }
}
