class BackendApiClient {
  BackendApiClient({required this.baseUrl});

  final String baseUrl;

  // TODO(윤현섭): /geofence/check, /bus-info/stops/{stopId}/arrivals,
  // /ride-requests API 연동 구현.
}
