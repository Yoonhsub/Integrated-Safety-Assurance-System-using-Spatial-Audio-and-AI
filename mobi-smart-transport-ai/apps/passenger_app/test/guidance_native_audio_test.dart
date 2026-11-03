import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_passenger_app/src/models/v3_guidance_models.dart';
import 'package:mobi_passenger_app/src/pages/v3_guidance_page.dart';
import 'package:mobi_passenger_app/src/services/local_guidance_runtime.dart';
import 'package:mobi_passenger_app/src/services/native_directional_cue_output.dart';
import 'package:mobi_passenger_app/src/services/session_guidance_audio.dart';
import 'package:mobi_passenger_app/src/services/session_safety_receiver.dart';
import 'package:mobi_passenger_app/src/services/speech_priority_coordinator.dart';
import 'package:mobi_passenger_app/src/services/spatial_verification_engine.dart';
import 'package:mobi_passenger_app/src/services/directional_guidance.dart';
import 'guidance_reconnect_test.dart' as existing;
import 'native_android_audio_test.dart' as native;
import 'session_safety_receiver_test.dart' as events;

class _Tts extends native.LocalTts {
  final spoken = <String>[];
  @override
  Future<dynamic> speak(String text, {bool focus = false}) {
    spoken.add(text);
    return super.speak(text, focus: focus);
  }
}

class _Transport implements SafetyPollingTransport {
  Map<String, dynamic> data = events.response(0);
  @override
  Future<Map<String, dynamic>> fetch(String s, int? c, String? g) async => {
        ...data,
        'events': (data['events'] as List)
            .where((e) => c == null || e['sequence'] > c)
            .toList(),
      };
  @override
  void close() {}
}

class _Client extends existing.RecoveringClient {
  final transport = _Transport();
  @override
  Future<V3GuidanceState> createSession({required String wakeWord}) async =>
      V3GuidanceState.fromJson({'sessionId': 'session', 'state': 'IDLE'});
  @override
  SafetyPollingTransport openSafetyPolling() => transport;
}

void main() {
  Future<void> flush(WidgetTester t) async {
    for (var i = 0; i < 60; i++) {
      await t.pump();
    }
  }

  void plugins() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in [
      'xyz.luan/audioplayers.global',
      'xyz.luan/audioplayers.global/events'
    ]) {
      messenger.setMockMethodCallHandler(
          MethodChannel(name), (_) async => null);
    }
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
  }

  testWidgets(
      'Android Guidance information and explicit local cue use native audio lifecycle',
      (t) async {
    for (final directed in [false, true]) {
      t.view.physicalSize = const Size(1100, 1700);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      plugins();
      final client = _Client(), tts = _Tts(), port = native.Port();
      final output = NativeDirectionalCueOutput(port: port);
      final engine = SpatialVerificationEngine(
          output,
          FlutterSpeechEngine.platform(
              tts: tts,
              requireOfflineKoreanVoice: true,
              requestNativeFocus: true),
          allowDirectTestCommands: false);
      final priority = SpeechPriorityCoordinator(engine);
      LocalDirectionReceipt? receipt;
      final audio = directed
          ? SessionGuidanceAudio.localVerification(
              priority: priority,
              engine: engine,
              authEpoch: () => 1,
              receipt: (_) => receipt)
          : SessionGuidanceAudio(priority: priority);
      final runtime = LocalGuidanceRuntime(
          client: client,
          auth: existing.DemoAuth(),
          captureGuard: () => () => true,
          priority: priority,
          audio: audio,
          controls: (_, __, ___) => const SizedBox());
      Widget page() => MaterialApp(
          home: V3GuidancePage(
              agentName: 'mobi',
              onReturnToModeSelection: () {},
              dataMode: 'live',
              localRuntime: runtime));
      await t.pumpWidget(page());
      await flush(t);
      expect(tts.spoken, ['안내가 시작되었습니다. 목적지를 말씀하거나 입력해 주세요.']);
      expect(tts.chosen!['name'], 'local');
      expect(tts.lastFocus, isTrue);
      await t.pumpWidget(page());
      await flush(t);
      expect(tts.spoken.length, 1);
      tts.completionHandler!();
      await flush(t);
      await t.tap(find.byType(Switch));
      await flush(t);
      receipt = LocalDirectionReceipt(
          sessionId: 'session',
          ownerUid: 'owner',
          generation: 'g',
          authEpoch: 1,
          eventId: 'e1',
          createdAt: DateTime.now(),
          direction: TestDirection.left);
      client.transport.data = events.response(1, events: [
        {...events.event(1), 'synthetic': directed}
      ]);
      await t.pump(const Duration(seconds: 1));
      await flush(t);
      if (directed) {
        expect(port.active!['direction'], 'LEFT');
        expect(tts.spoken.length, 1);
        port.finish();
        await flush(t);
      } else {
        expect(port.calls.where((c) => c == 'play'), isEmpty);
      }
      expect(tts.spoken.length, 2);
      await t.pump(const Duration(seconds: 4));
      await flush(t);
      expect(tts.spoken.length, 2);
      tts.completionHandler!();
      await flush(t);
      await t.pump(const Duration(seconds: 1));
      await flush(t);
      expect(tts.spoken.length, 2);
      client.transport.data = events.response(2, events: [
        {...events.event(2), 'synthetic': directed}
      ]);
      receipt = LocalDirectionReceipt(
          sessionId: 'session',
          ownerUid: 'owner',
          generation: 'g',
          authEpoch: 1,
          eventId: 'e2',
          createdAt: DateTime.now(),
          direction: TestDirection.right);
      await t.pump(const Duration(seconds: 1));
      await flush(t);
      if (directed) {
        port.finish();
        await flush(t);
      }
      expect(tts.spoken.length, 3);
      await t.tap(find.text('안내 일시 정지 (Live Hold)'));
      await flush(t);
      expect(priority.priorityActive, isTrue);
      tts.completionHandler!(); // Old completion cannot revive a held event.
      await t.tap(find.text('새 안내 허용'));
      await flush(t);
      expect(tts.spoken.length, 3);
      await t.tap(find.byType(Switch));
      client.transport.data = events.response(3, events: [
        {...events.event(3), 'synthetic': directed}
      ]);
      receipt = LocalDirectionReceipt(
          sessionId: 'session',
          ownerUid: 'owner',
          generation: 'g',
          authEpoch: 1,
          eventId: 'e3',
          createdAt: DateTime.now(),
          direction: TestDirection.center);
      await t.pump(const Duration(seconds: 1));
      await flush(t);
      if (directed) {
        expect(port.active!['direction'], 'CENTER');
        expect(tts.spoken.length, 3);
      } else {
        expect(tts.spoken.length, 4);
      }
      await t.tap(find.text('음성 중지 (STOP)'));
      await flush(t);
      await t.pumpWidget(const SizedBox());
      await flush(t);
      tts.completionHandler!(); // Late completion after exit cannot restart audio.
      await flush(t);
      expect(tts.spoken.length, directed ? 3 : 4);
      await engine.dispose();
      priority.dispose();
      expect(port.active, isNull);
      expect(t.takeException(), isNull);
    }
  });
}
