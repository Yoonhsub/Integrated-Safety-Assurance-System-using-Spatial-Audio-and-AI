import 'dart:async';
import 'package:mobi_passenger_app/src/services/speech_priority_coordinator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_passenger_app/src/pages/local_spatial_verification_page.dart';
import 'package:mobi_passenger_app/src/services/spatial_verification_engine.dart';
import 'package:mobi_passenger_app/src/services/audio_haptic_cue_service.dart';
import 'vision_observation_tts_test.dart' as f;

class Output implements SpatialTestOutput {
  final commands = <String>[];
  final pending = <Completer<bool>>[];
  Completer<void>? preparing;
  bool failStop = false, disposed = false;
  int stops = 0;
  @override
  Future<void> prepareFromGesture() async {
    await preparing?.future;
  }

  @override
  Future<bool> play(String mode, String direction) {
    commands.add('$mode:$direction');
    final c = Completer<bool>();
    pending.add(c);
    return c.future;
  }

  void finish() {
    for (final p in pending) {
      if (!p.isCompleted) p.complete(true);
    }
  }

  @override
  Future<void> stop() async {
    stops++;
    if (failStop) throw StateError('stop failed');
    for (final p in pending) {
      if (!p.isCompleted) p.complete(false);
    }
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    finish();
  }

  @override
  Map<String, dynamic> snapshot() =>
      {'phase': 'fake', 'active': pending.any((p) => !p.isCompleted)};
}

void main() {
  for (final scenario in [
    'complete',
    'hold',
    'end',
    'logout',
    'reset',
    'rapid',
    'dispose',
    'stop-failure',
    'default-blocked',
    'tts',
    'pending-prepare'
  ]) {
    testWidgets('spatial lifecycle $scenario', (t) async {
      t.view.physicalSize = const Size(1600, 2000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final output = Output(), speech = f.FakeTts();
      if (scenario == 'pending-prepare') output.preparing = Completer<void>();
      await t.pumpWidget(MaterialApp(
          home: LocalSpatialVerificationPage(
              enabled: scenario != 'default-blocked',
              output: output,
              tts: speech,
              cuesFactory: (p) => AudioHapticCueService(
                  speechPriority: p,
                  audioPlayer: f.FakePlayer(),
                  liveAudioPlayer: f.FakeLive()))));
      await t.pump();
      expect(output.commands, isEmpty);
      expect(speech.spoken, isEmpty);
      if (scenario == 'default-blocked') {
        expect(find.text('SPATIAL_VERIFICATION_BLOCKED'), findsOneWidget);
      } else {
        await t.tap(find.text('STEREO LEFT'));
        await t.pump();
        if (scenario == 'pending-prepare') {
          await t.tap(find.text('세션 종료'));
          await t.pump();
          output.preparing!.complete();
          await t.pump();
          expect(output.commands, isEmpty);
        } else {
          expect(output.commands, ['STEREO:LEFT']);
          if (scenario == 'complete') {
            output.finish();
            await t.pump();
            expect(
                find.textContaining('STEREO LEFT COMPLETED'), findsOneWidget);
          } else if (scenario == 'hold') {
            await t.tap(find.text('Live Hold 선점'));
            await t.pump();
            expect(output.stops, greaterThan(0));
            expect(speech.spoken.single, contains('검증용 Live Hold'));
            speech.finish();
            await t.pump();
            expect(output.commands.length, 1);
            expect(find.text('LIVE_HOLD_COMPLETED'), findsOneWidget);
          } else if (scenario == 'rapid') {
            await t.tap(find.text('STEREO RIGHT'));
            await t.pump();
            await t.tap(find.text('HRTF CENTER'));
            await t.pump();
            expect(output.commands,
                ['STEREO:LEFT', 'STEREO:RIGHT', 'HRTF:CENTER']);
            expect(output.pending.where((p) => !p.isCompleted).length, 1);
          } else if (scenario == 'tts') {
            await t.tap(find.text('TTS 원본 출력'));
            await t.pump();
            expect(output.stops, greaterThan(0));
            expect(speech.spoken, ['테스트 음성 출력입니다.']);
            await t.tap(find.text('STEREO RIGHT'));
            await t.pump();
            expect(speech.stops, greaterThan(0));
            expect(output.commands.last, 'STEREO:RIGHT');
          } else if (scenario == 'dispose') {
            await t.pumpWidget(const SizedBox());
            await t.pump();
            expect(output.disposed, true);
            expect(output.commands.length, 1);
          } else {
            if (scenario == 'stop-failure') output.failStop = true;
            final button = scenario == 'end'
                ? '세션 종료'
                : scenario == 'logout'
                    ? '로그아웃'
                    : scenario == 'reset'
                        ? 'Reset / 새 generation'
                        : 'STOP';
            await t.tap(find.text(button));
            await t.pump();
            await t.pump();
            if (scenario == 'stop-failure') {
              expect(find.textContaining('AUDIO_BLOCKED'), findsOneWidget);
              expect(output.commands.length, 1);
            } else {
              expect(output.stops, greaterThan(0));
              output.finish();
              await t.pump();
              if (scenario == 'reset') {
                expect(find.textContaining('generation=2'), findsWidgets);
                await t.tap(find.text('HRTF RIGHT'));
                await t.pump();
                expect(output.commands.last, 'HRTF:RIGHT');
              } else {
                await t.tap(find.text('STEREO RIGHT'), warnIfMissed: false);
                await t.pump();
                expect(output.commands.length, 1);
              }
            }
          }
        }
      }
      await t.pumpWidget(const SizedBox());
      await t.pump();
    });
  }
  test('old TTS preparation cannot emit speech after stop', () async {
    final output = Output(),
        speech = f.FakeTts()..preparing = Completer<void>();
    final engine = SpatialVerificationEngine(output, speech);
    final old = engine.speak('old');
    final expectation = expectLater(old, throwsA(isA<SpeechCancelled>()));
    await engine.stop();
    speech.preparing!.complete();
    await expectation;
    expect(speech.spoken, isEmpty);
    await engine.dispose();
  });
}
