class BackendApiClient {
  BackendApiClient({required this.baseUrl});

  final String baseUrl;

  // TODO(윤현섭): FCM 수신 핸들러 연동, /drivers/{driverId}/ride-requests,
  // /ride-requests/{requestId}/status API 연동 구현.
}
