import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobi_mobile_auth/mobile_auth.dart';
import 'package:mobi_passenger_app/src/pages/v3_guidance_page.dart';
import 'package:mobi_passenger_app/src/models/v3_guidance_models.dart';
import 'package:mobi_passenger_app/src/services/v3_agent_api_client.dart';
import 'package:mobi_passenger_app/src/services/local_guidance_runtime.dart';
import 'package:mobi_passenger_app/src/services/session_guidance_audio.dart';
import 'package:mobi_passenger_app/src/services/speech_priority_coordinator.dart';

class SilentSpeech implements SpeechEngine {
  @override
  Future<void> prepare({required bool requireKoreanVoice}) async {}
  @override
  Future<void> speak(String text) async {}
  @override
  Future<void> stop() async {}
}

class DemoAuth implements AuthSession {
  @override
  AuthAccount get currentAccount => const AuthAccount(uid: 'owner');
  @override
  Stream<AuthAccount?> get authStateChanges => const Stream.empty();
  @override
  Future<String?> getIdToken({bool forceRefresh = false}) async => 'local-test';
  @override
  Future<Object?> getCustomClaim(String name,
          {bool forceRefresh = false}) async =>
      null;
  @override
  Future<void> signOut() async {}
  @override
  Future<AuthAccount> signIn(String email, String password) async =>
      currentAccount;
}

class RecoveringClient extends V3AgentApiClient {
  RecoveringClient()
      : super(
            baseUrl: 'http://127.0.0.1:18459',
            visionLeaseEnabled: false,
            authClient: AuthenticatedApiClient(
                tokenLoader: ({bool forceRefresh = false}) async =>
                    'local-test',
                requestGuard: () => () => true,
                client: MockClient((_) async => http.Response(
                    jsonEncode({
                      'sessionId': 'recovered',
                      'ownerUid': 'owner',
                      'generation': 'g',
                      'cursor': 0,
                      'events': []
                    }),
                    200))));
  int starts = 0, reads = 0;
  @override
  Future<V3HealthStatus> fetchHealth() async =>
      const V3HealthStatus(isAvailable: true, message: 'local test');
  @override
  Future<V3GuidanceState> createSession({required String wakeWord}) async {
    starts++;
    if (starts == 1) throw StateError('server unavailable');
    return V3GuidanceState.fromJson(
        {'sessionId': 'recovered', 'state': 'IDLE'});
  }

  @override
  Future<V3GuidanceState> fetchState({required String sessionId}) async {
    reads++;
    expect(sessionId, 'recovered');
    return V3GuidanceState.fromJson({'sessionId': sessionId, 'state': 'IDLE'});
  }
}

void main() {
  testWidgets(
      'failed first Guidance session can reconnect without reopening app',
      (tester) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        const MethodChannel('xyz.luan/audioplayers.global'), (_) async => null);
    messenger.setMockMethodCallHandler(
        const MethodChannel('xyz.luan/audioplayers.global/events'),
        (_) async => null);
    messenger.setMockMethodCallHandler(
        const MethodChannel('xyz.luan/audioplayers'), (call) async {
      if (call.method == 'create') {
        final id = (call.arguments as Map)['playerId'];
        messenger.setMockMethodCallHandler(
            MethodChannel('xyz.luan/audioplayers/events/$id'),
            (_) async => null);
      }
      return null;
    });
    final client = RecoveringClient();
    final priority = SpeechPriorityCoordinator(SilentSpeech());
    final runtime = LocalGuidanceRuntime(
        client: client,
        auth: DemoAuth(),
        captureGuard: () => () => true,
        priority: priority,
        audio: SessionGuidanceAudio(priority: priority),
        controls: (_, __, ___) => const SizedBox());
    await tester.pumpWidget(MaterialApp(
        home: V3GuidancePage(
            agentName: 'mobi',
            onReturnToModeSelection: () {},
            dataMode: 'mock',
            localRuntime: runtime)));
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
    expect(client.starts, 1);
    expect(find.byTooltip('서버 다시 연결'), findsOneWidget);
    await tester.tap(find.byTooltip('서버 다시 연결'));
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
    expect(client.starts, 2);
    expect(client.reads, 0);
    expect(find.byTooltip('상태 새로고침'), findsOneWidget);
    await tester.tap(find.byTooltip('상태 새로고침'));
    await tester.pump();
    expect(client.reads, 1);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    priority.dispose();
  });
}
