import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobi_mobile_auth/mobile_auth.dart';
import 'src/pages/local_tts_verification_page.dart';
import 'src/services/audio_haptic_cue_service.dart';
import 'src/services/speech_priority_coordinator.dart';
import 'src/services/v3_agent_api_client.dart';

/// Local debug entry only. No Firebase initialization or production auth bypass.
Future<void> main() async {
  const enabled = bool.fromEnvironment('MOBI_LOCAL_TTS_VERIFICATION');
  if (!enabled ||
      !kDebugMode ||
      !kIsWeb ||
      !{'localhost', '127.0.0.1'}.contains(Uri.base.host)) {
    throw StateError(
        'Local TTS verification requires an explicit localhost debug build');
  }
  WidgetsFlutterBinding.ensureInitialized();
  final font = FontLoader('OfflineKorean')
    ..addFont(rootBundle.load('offline-test.ttf'));
  await font.load();
  const backend = 'http://127.0.0.1:8280';
  final api = V3AgentApiClient(
      baseUrl: backend,
      authClient: AuthenticatedApiClient(
          tokenLoader: ({bool forceRefresh = false}) async =>
              'offline-only.owner'));
  final admin = AuthenticatedApiClient(
      tokenLoader: ({bool forceRefresh = false}) async => 'offline-only.admin');
  final cues = AudioHapticCueService(speechPriority: sharedSpeechPriority);
  Future<Map<String, dynamic>> emit(String session, String generation) async {
    final fixture = await admin.get(Uri.parse('$backend/__test/fixture'));
    if (fixture.statusCode != 200) {
      throw StateError('Local fixture unavailable');
    }
    final response = await admin.post(
        Uri.parse('$backend/ai-vision/events').replace(
            queryParameters: {'sessionId': session, 'generation': generation}),
        headers: {'Content-Type': 'application/json'},
        body: fixture.body);
    final body = jsonDecode(response.body) as Map;
    return {
      'httpStatus': response.statusCode,
      'stored': body['stored'],
      'source': (body['safetyEvent'] as Map?)?['source']
    };
  }

  Future<String> hold(String session) async {
    final prepared = await admin.post(Uri.parse('$backend/__test/hold-context')
        .replace(queryParameters: {'sessionId': session}));
    if (prepared.statusCode != 200) {
      throw StateError('Local context unavailable');
    }
    final response = await api.converse(
        sessionId: session,
        wakeWord: '자비스',
        utterance: '자비스, 지금 앞에 온 버스 타도 돼?',
        mode: 'live');
    if (response.usedGemini || response.ttsMode != 'SAFETY_LOCAL') {
      throw StateError('Nonlocal Hold refused');
    }
    return response.message;
  }

  runApp(MaterialApp(
      theme: ThemeData(fontFamily: 'OfflineKorean'),
      home: LocalTtsVerificationPage(
          enabled: true,
          api: api,
          priority: sharedSpeechPriority,
          cues: cues,
          emitSynthetic: emit,
          fetchHold: hold)));
}
