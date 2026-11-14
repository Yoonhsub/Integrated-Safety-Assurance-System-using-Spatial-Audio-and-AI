import '../models/v3_guidance_models.dart';

String routeDataSourceLabel(String source) => switch (source) {
      'MOCK' => '시연 데이터 · 실제 버스 운행 정보 아님',
      'CACHE' => '저장된 자료 · 원본 출처와 최신 여부 미확인',
      'PUBLIC_API' => '공공 API 자료 · 실제 차량 식별 확인 아님',
      'ERROR' => '자료 조회 실패 · 연결 확인 후 새로고침',
      _ => '자료 출처 미확인 · 새로고침으로 다시 확인',
    };

String routePlanSourceLabel(V3RoutePlanCandidate plan) {
  // A planner/provider name must not upgrade mock/cache provenance to live.
  if (plan.fallbackSource != 'PUBLIC_API') {
    return routeDataSourceLabel(plan.fallbackSource);
  }
  final provider = switch (plan.planSource) {
    'ODSAY_ENRICHED' => 'ODsay 경로 + 청주 공공데이터 대조',
    'ODSAY' => 'ODsay 경로',
    'LOCAL_FALLBACK' => '청주 공공데이터 기반 경로 계산',
    _ => '경로 제공자 미확인',
  };
  return '$provider · 실시간 도착과 차량 일치는 별도 확인 필요';
}

String arrivalFreshnessLabel(List<V3BusArrival> arrivals, DateTime now) {
  if (arrivals.isEmpty) return '현재 표시할 도착 정보가 없습니다. 새로고침해 주세요.';
  if (arrivals.any((a) => a.updatedAt == null)) {
    return '도착 자료 시각 미확인 · 최신 정보로 간주하지 마세요.';
  }
  final times = arrivals.map((a) => a.updatedAt!.toUtc()).toList()..sort();
  if (times.any((t) => t.isAfter(now.toUtc()))) {
    return '도착 자료 시각 오류 · 기기 시각과 연결을 확인하고 새로고침해 주세요.';
  }
  final oldest = times.first;
  final age = now.toUtc().difference(oldest);
  final state = age >= const Duration(seconds: 30)
      ? '30초 이상 지난 도착 자료 · 새로고침 필요'
      : '도착 자료 시각 확인됨 · 이후 운행 변동 가능';
  return '$state (가장 오래된 자료: ${oldest.toIso8601String()})';
}

/// A new empty/error response must not revive arrivals from an earlier plan.
List<V3BusArrival> displayedRouteArrivals({
  required List<V3BusArrival>? latest,
  required List<V3BusArrival> planned,
}) =>
    latest ?? planned;

String routeFailureNextAction(String status) => switch (status) {
      'NEEDS_CHOICE' || 'NEEDS_CONFIRMATION' => '목적지 후보를 확인해 선택해 주세요.',
      'NO_ROUTE' =>
        '직통·1회 환승 후보를 찾지 못했습니다. 가까운 정류장이나 다른 목적지를 검색해 주세요. 운행 종료를 뜻하지는 않습니다.',
      'NOT_FOUND' => '위치 권한과 목적지 이름을 확인한 뒤 다시 검색해 주세요.',
      'ERROR' => '네트워크 연결을 확인한 뒤 다시 검색해 주세요.',
      _ => '목적지 이름과 위치 권한을 확인한 뒤 다시 검색해 주세요.',
    };
