import 'dart:async';
import 'package:flutter/material.dart';
import '../models/v3_guidance_models.dart';
import '../services/route_data_presentation.dart';

class RouteDataStatus extends StatefulWidget {
  const RouteDataStatus(
      {super.key,
      required this.source,
      required this.arrivals,
      this.now,
      this.planningSnapshot = false});
  final String source;
  final List<V3BusArrival> arrivals;
  final DateTime? now;
  final bool planningSnapshot;
  @override
  State<RouteDataStatus> createState() => _RouteDataStatusState();
}

class _RouteDataStatusState extends State<RouteDataStatus> {
  Timer? _refresh;
  @override
  void initState() {
    super.initState();
    // Age the displayed observation even while a subsequent request fails.
    _refresh = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted &&
          widget.now == null &&
          widget.arrivals.any((arrival) => arrival.updatedAt != null)) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _refresh?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
        container: true,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(routeDataSourceLabel(widget.source)),
          if (widget.planningSnapshot)
            const Text('경로 계산 당시 자료 · 새 도착 조회 결과 아님'),
          Text(arrivalFreshnessLabel(
              widget.arrivals, widget.now ?? DateTime.now().toUtc())),
          const Text('도착 예상은 변동될 수 있으며 눈앞 차량이나 승차 가능 여부를 확인하지 않습니다.'),
        ]),
      );
}
