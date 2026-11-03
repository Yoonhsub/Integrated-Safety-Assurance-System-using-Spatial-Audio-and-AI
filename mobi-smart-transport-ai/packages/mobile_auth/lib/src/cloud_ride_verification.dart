import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'auth_only_configuration.dart';
import 'authenticated_http_client.dart';
import 'firebase_auth_service.dart';
import 'firebase_configuration.dart';

/// Fixed source registrations are not approval to execute cloud requests.
/// Normal application entrypoints never read this configuration.
class CloudRidePlan {
  const CloudRidePlan._(this.dataRun, this.caseId, this.requestId,
      this.backendUrl, this.offlineOnly);

  static const project = 'mobi-auth-cloud-test';
  static const authRun = 'auth-20261023-919e07bd';
  static const databaseUrl =
      'https://mobi-auth-cloud-test-default-rtdb.asia-southeast1.firebasedatabase.app';
  // Retirement overrides historical positive registrations and cached intents.
  static const _retiredDataRuns = <String>{
    'rtdb-20261025-6e9a7c42',
    'rtdb-20261026-b742c9e1',
  };
  static const _reviewedCloudRuns = <String, CloudRidePlan>{
    'rtdb-20261026-b742c9e1': CloudRidePlan._(
        'rtdb-20261026-b742c9e1',
        'ride-e2e-01',
        'ride-i-7fb9e7e421703f7440ba60c2da81f77083a03fc21ee2399d40cc7bc9ac92344a',
        'http://127.0.0.1:8023',
        false),
  };

  /// Exercise the exact source registration with injected SDK/HTTP fakes.
  /// This does not initialize Auth, create transport, or enable an entrypoint.
  @visibleForTesting
  factory CloudRidePlan.reviewedForTesting(String run) {
    if (!kDebugMode) throw StateError('Plan inspection requires a debug test');
    final plan = _reviewedCloudRuns[run];
    if (plan == null) throw StateError('Unregistered cloud ride plan');
    plan.validate();
    return plan;
  }

  factory CloudRidePlan.fromEnvironment({required String role}) {
    const enabled = bool.fromEnvironment('MOBI_CLOUD_RIDE_VERIFICATION');
    const run = String.fromEnvironment('MOBI_CLOUD_RIDE_DATA_RUN');
    final plan = _reviewedCloudRuns[run];
    if (!enabled ||
        !kIsWeb ||
        !{'127.0.0.1', 'localhost'}.contains(Uri.base.host) ||
        plan == null ||
        plan.offlineOnly) {
      throw StateError(
          'Cloud ride verification has no reviewed execution plan');
    }
    plan.validate();
    plan.validateWeb(FirebaseWebConfiguration.fromEnvironment(), role);
    return plan;
  }

  /// Synthetic local-only fixture; unreachable from environment registration.
  /// Not accepted in release/profile builds or by the cloud Backend registry.
  @visibleForTesting
  factory CloudRidePlan.offlineFixture() {
    if (!kDebugMode) throw StateError('Offline plan requires a debug test');
    return const CloudRidePlan._(
        'rtdb-offline-ui-fixture',
        'ui-e2e-01',
        'ride-i-c4002cf41924da1616e42e03807ab6ea25accb1d6d20364de0fb18148af7f2cb',
        'http://127.0.0.1:8023',
        true);
  }

  final String dataRun, caseId, requestId, backendUrl;
  final bool offlineOnly;
  String uid(String suffix) => 'ct-$authRun-$suffix';
  String get stopId => 'ct-$dataRun-stop-502';
  String get idempotencyKey => 'cloud-test:$dataRun:$caseId';
  String get path => '/cloudTestRuns/$dataRun';

  void validate() {
    final url = Uri.parse(backendUrl);
    if ((offlineOnly && !kDebugMode) ||
        (!offlineOnly && !identical(_reviewedCloudRuns[dataRun], this)) ||
        !RegExp(r'^[a-z0-9][a-z0-9-]{7,23}$').hasMatch(dataRun) ||
        _retiredDataRuns.contains(dataRun) ||
        url.scheme != 'http' ||
        url.host != '127.0.0.1' ||
        !url.hasPort ||
        url.port < 1024 ||
        url.path.isNotEmpty ||
        url.hasQuery ||
        url.hasFragment ||
        url.userInfo.isNotEmpty) {
      throw StateError('Invalid reviewed cloud ride plan');
    }
  }

  void validateWeb(FirebaseWebConfiguration config, String role) {
    validate();
    if (!{'passenger', 'driver'}.contains(role) ||
        !const AuthOnlyConfiguration(
                enabled: true, projectId: project, runId: authRun)
            .matchesWebConfiguration(config, requiredRole: role)) {
      throw StateError('Cloud ride Web registration mismatch');
    }
  }

  bool accepts(String uid, String role, Object? run, String? driverId) =>
      const AuthOnlyConfiguration(
              enabled: true, projectId: project, runId: authRun)
          .accepts(uid, role, run, driverId);

  void validateDraft(Map<String, Object?> draft) {
    final expected = {
      'userId': uid('passenger-a'),
      'stopId': stopId,
      'routeId': 'MOCK-502',
      'busNo': '502'
    };
    if (draft.length != expected.length ||
        expected.entries.any((e) => draft[e.key] != e.value)) {
      throw const AuthenticatedApiException(403);
    }
  }

  CloudRideBinding bind(
      {required FirebaseAuthSession session,
      required FirebaseWebConfiguration web,
      required String role,
      http.Client? transport}) {
    validateWeb(web, role);
    validateWeb(session.webConfiguration, role);
    return CloudRideBinding._(
        this, session, web, role, transport ?? http.Client());
  }
}

/// Real Firebase Auth is retained. Only the public bus GET is a local fixture.
class CloudRideBinding {
  CloudRideBinding._(
      this.plan, this.session, this.web, this.role, this._transport) {
    publicClient = _CloudRideTransport(this, true);
    authClient = AuthenticatedApiClient(
        client: _CloudRideTransport(this, false),
        tokenLoader: token,
        requestGuard: session.captureRequestGuard,
        onUnauthorized: session.signOut);
  }
  final CloudRidePlan plan;
  final FirebaseAuthSession session;
  final FirebaseWebConfiguration web;
  final String role;
  final http.Client _transport;
  late final http.Client publicClient;
  late final AuthenticatedApiClient authClient;
  String? _issuedToken, _issuedUid;

  void validate() => plan.validateWeb(web, role);

  Future<String?> token({bool forceRefresh = false}) async {
    final isCurrent = session.captureRequestGuard();
    void check() {
      if (!isCurrent()) throw const StaleAuthRequestException();
    }

    check();
    validate();
    // Validate the exact Auth delegate, not an unrelated/default Firebase app.
    plan.validateWeb(session.webConfiguration, role);
    final account = session.currentAccount;
    if (account == null) throw const AuthenticatedApiException(401);
    final observedRole = await session.getCustomClaim('mobi_role');
    check();
    final run = await session.getCustomClaim('mobi_cloud_test_run');
    check();
    final driver = await session.getCustomClaim('mobi_driver_id');
    check();
    if (observedRole != role ||
        (driver != null && driver is! String) ||
        !plan.accepts(account.uid, role, run, driver as String?)) {
      throw const AuthenticatedApiException(403);
    }
    final value = await session.getIdToken(forceRefresh: forceRefresh);
    check();
    if (session.currentAccount?.uid != account.uid) {
      throw const AuthenticatedApiException(401);
    }
    _issuedToken = value;
    _issuedUid = account.uid;
    return value;
  }

  void checkRequestAccount(http.BaseRequest request) {
    if (_issuedToken == null ||
        session.currentAccount?.uid != _issuedUid ||
        request.headers['Authorization'] != 'Bearer $_issuedToken') {
      throw const StaleAuthRequestException();
    }
  }

  Future<http.Response> health() async {
    validate();
    final request = http.Request('GET', Uri.parse('${plan.backendUrl}/health'))
      ..followRedirects = false;
    final result = await http.Response.fromStream(
        await _transport.send(request).timeout(const Duration(seconds: 5)));
    final data = result.statusCode == 200 ? jsonDecode(result.body) : null;
    if (data is! Map ||
        data['cloudTestProjectId'] != CloudRidePlan.project ||
        data['cloudTestRunId'] != plan.dataRun) {
      throw const AuthenticatedApiException(503);
    }
    return result;
  }

  void close() {
    _issuedToken = null;
    _issuedUid = null;
    _transport.close();
  }
}

class _CloudRideTransport extends http.BaseClient {
  _CloudRideTransport(this.binding, this.public);
  final CloudRideBinding binding;
  final bool public;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final isCurrent = binding.session.captureRequestGuard();
    final plan = binding.plan;
    binding.validate();
    final url = request.url;
    if (url.origin != plan.backendUrl ||
        url.hasQuery ||
        url.hasFragment ||
        url.userInfo.isNotEmpty) throw const AuthenticatedApiException(403);
    final path = url.path;
    if (public) {
      if (request.method == 'GET' && path == '/health') {
        return _stream(await binding.health());
      }
      if (request.method == 'GET' &&
          path == '/bus-info/stops/mock-stop-001/arrivals') {
        return _stream(http.Response(
            jsonEncode({
              'stopId': plan.stopId,
              'arrivals': [
                {
                  'routeId': 'MOCK-502',
                  'busNo': '502',
                  'arrivalMinutes': 2,
                  'remainingStops': 1,
                  'lowFloor': true,
                  'congestion': 'NORMAL',
                  'updatedAt': '2026-10-26T00:00:00Z'
                }
              ]
            }),
            200,
            headers: {
              'content-type': 'application/json; charset=utf-8',
              'x-mobi-local-fixture': 'bus-arrivals'
            }));
      }
      throw const AuthenticatedApiException(403);
    }
    final record = '/ride-requests/${plan.requestId}';
    final listPaths = {
      '/drivers/${plan.uid('driver-502')}/ride-requests',
      '/drivers/${plan.uid('driver-105')}/ride-requests'
    };
    if (request.method == 'POST' && path == '/ride-requests') {
      if (request is! http.Request ||
          request.headers['Idempotency-Key'] != plan.idempotencyKey) {
        throw const AuthenticatedApiException(403);
      }
      plan.validateDraft(
          Map<String, Object?>.from(jsonDecode(request.body) as Map));
    } else if (request.method == 'PATCH' && path == '$record/status') {
      if (request is! http.Request) throw const AuthenticatedApiException(403);
      final body = jsonDecode(request.body);
      if (body is! Map ||
          body.length != 1 ||
          !{'ACCEPTED', 'CANCELLED'}.contains(body['status'])) {
        throw const AuthenticatedApiException(403);
      }
    } else if (!(request.method == 'GET' &&
        (path == record || listPaths.contains(path)))) {
      throw const AuthenticatedApiException(403);
    }
    if (!isCurrent()) throw const StaleAuthRequestException();
    binding.checkRequestAccount(request);
    await binding
        .health(); // Check the server's pinned data run before each action.
    if (!isCurrent()) throw const StaleAuthRequestException();
    binding.checkRequestAccount(request);
    request.followRedirects = false;
    return binding._transport.send(request);
  }

  http.StreamedResponse _stream(http.Response response) =>
      http.StreamedResponse(
          Stream.value(response.bodyBytes), response.statusCode,
          headers: response.headers);
}
