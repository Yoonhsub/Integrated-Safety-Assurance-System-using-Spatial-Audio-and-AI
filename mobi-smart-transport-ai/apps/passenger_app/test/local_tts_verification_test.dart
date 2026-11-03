import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobi_mobile_auth/mobile_auth.dart';
import 'package:mobi_passenger_app/src/pages/local_tts_verification_page.dart';
import 'package:mobi_passenger_app/src/services/v3_agent_api_client.dart';
import 'package:mobi_passenger_app/src/services/speech_priority_coordinator.dart';
import 'package:mobi_passenger_app/src/services/audio_haptic_cue_service.dart';
import 'vision_observation_tts_test.dart' as fixtures;

class FailingStop extends fixtures.FakeTts {
  @override
  Future<void> stop() async {
    throw StateError('native stop failed');
  }
}

void main() {
  for (final scenario in [
    'no-auto',
    'complete',
    'hold',
    'hold-backend-failure',
    'end',
    'same-uid',
    'dispose',
    'no-local-voice',
    'stop-failure',
    'default-blocked'
  ]) {
    testWidgets('explicit TTS verification $scenario', (t) async {
      final engine =
          scenario == 'stop-failure' ? FailingStop() : fixtures.FakeTts();
      final priority = SpeechPriorityCoordinator(engine);
      final cues = AudioHapticCueService(
          speechPriority: priority,
          audioPlayer: fixtures.FakePlayer(),
          liveAudioPlayer: fixtures.FakeLive());
      final api = V3AgentApiClient(
          baseUrl: 'http://tts-$scenario.test',
          authClient: AuthenticatedApiClient(
              tokenLoader: ({bool forceRefresh = false}) async =>
                  'offline-only.owner',
              client: MockClient((r) async {
                if (r.url.path == '/guidance/session') {
                  return http.Response(
                      jsonEncode(
                          {'sessionId': 'test-session', 'state': 'IDLE'}),
                      200);
                }
                return http.Response(
                    jsonEncode({
                      'sessionId': 'test-session',
                      'ownerUid': 'owner',
                      'generation': 'g',
                      'cursor': 0,
                      'events': []
                    }),
                    200);
              })));
      await t.pumpWidget(MaterialApp(
          home: LocalTtsVerificationPage(
              enabled: scenario != 'default-blocked',
              api: api,
              priority: priority,
              cues: cues,
              probe: () => {
                    'supported': true,
                    'phase': 'idle',
                    'localKoreanAvailable': scenario != 'no-local-voice'
                  },
              emitSynthetic: (s, g) async => {
                    'httpStatus': 201,
                    'stored': true,
                    'source': 'ai_vision_mock'
                  },
              fetchHold: (s) async {
                if (scenario == 'hold-backend-failure') {
                  throw StateError('local backend unavailable');
                }
                return '현재 정보만으로는 승차 여부를 확인하지 못했어요.';
              })));
      await t.pump();
      await t.pump(const Duration(milliseconds: 250));
      await t.pump();
      expect(engine.spoken, isEmpty);
      if (scenario == 'default-blocked') {
        expect(find.text('LOCAL_TTS_VERIFICATION_BLOCKED'), findsOneWidget);
      } else if (scenario == 'no-local-voice') {
        final button = t.widget<ElevatedButton>(find.ancestor(
            of: find.text('1. 테스트 음성 출력'),
            matching: find.byType(ElevatedButton)));
        expect(button.onPressed, isNull);
      } else if (scenario == 'no-auto') {
        await t.pump(const Duration(seconds: 3));
        expect(engine.spoken, isEmpty);
      } else {
        await t.tap(find.text('1. 테스트 음성 출력'));
        await t.pump();
        expect(engine.spoken, ['테스트 음성 출력입니다.']);
        await t.tap(find.text('1. 테스트 음성 출력'), warnIfMissed: false);
        await t.pump();
        expect(engine.spoken.length, 1);
        if (scenario == 'complete') {
          engine.finish();
          await t.pump();
          expect(find.textContaining('MANUAL_COMPLETION_CONFIRMED'),
              findsOneWidget);
        } else if (scenario == 'hold-backend-failure') {
          engine.finish();
          await t.pump();
          await t.tap(find.text('3. Live Hold 선점'));
          await t.pump();
          expect(
              find.textContaining('LIVE_HOLD_BACKEND_FAILED'), findsOneWidget);
          expect(find.textContaining('AUDIO_BLOCKED'), findsNothing);
          expect(engine.spoken.length, 1);
          await t.tap(find.text('1. 테스트 음성 출력'));
          await t.pump();
          expect(engine.spoken.length, 2);
          engine.finish();
          await t.pump();
        } else if (scenario == 'hold') {
          await t.tap(find.text('3. Live Hold 선점'));
          await t.pump();
          expect(engine.stops, greaterThan(0));
          expect(engine.spoken.length, 2);
          expect(engine.spoken.last, startsWith('검증용 Live Hold'));
          engine.finish();
          await t.pump();
          expect(engine.spoken.length, 2);
        } else if (scenario == 'dispose') {
          await t.pumpWidget(const SizedBox());
          await t.pump();
          expect(engine.stops, greaterThan(0));
          engine.finish();
          await t.pump();
          expect(engine.spoken.length, 1);
        } else {
          await t.tap(find
              .text(scenario == 'same-uid' ? '동일 UID 재로그인' : '4. 세션 종료·음성 중지'));
          await t.pump();
          await t.pump();
          if (scenario == 'stop-failure') {
            expect(find.textContaining('AUDIO_BLOCKED'), findsOneWidget);
            expect(engine.spoken.length, 1);
          } else {
            expect(engine.stops, greaterThan(0));
            engine.finish();
            await t.pump();
            expect(engine.spoken.length, 1);
          }
        }
      }
      await t.pumpWidget(const SizedBox());
      await t.pump();
      priority.dispose();
    });
  }
}
