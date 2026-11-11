import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_passenger_app/src/pages/door_approach_demo_page.dart';
import 'package:mobi_passenger_app/src/services/directional_guidance.dart';
import 'package:mobi_passenger_app/src/services/spatial_verification_engine.dart';
import 'package:mobi_passenger_app/src/services/speech_priority_coordinator.dart';

class CuePort implements SpatialTestOutput, DirectionalCueOutput {
  Completer<void>? preparing;
  final directions = <TestDirection>[];
  int stops = 0;
  bool failStop = false;
  @override
  Future<void> prepareFromGesture() async {
    await preparing?.future;
  }

  @override
  Future<bool> playCue(TestDirection direction) async {
    directions.add(direction);
    return true;
  }

  @override
  Future<bool> play(String mode, String direction) async => true;
  @override
  Future<void> stop() async {
    stops++;
    if (failStop) throw StateError('output stop not acknowledged');
  }

  @override
  Future<void> dispose() async {}
  @override
  Map<String, dynamic> snapshot() => {};
}

class Voice implements SpeechEngine {
  final spoken = <String>[];
  Completer<void>? pending;
  int stops = 0;
  @override
  Future<void> prepare({required bool requireKoreanVoice}) async {}
  @override
  Future<void> speak(String text) {
    spoken.add(text);
    pending = Completer();
    return pending!.future;
  }

  @override
  Future<void> stop() async {
    stops++;
    if (pending?.isCompleted == false) pending!.complete();
  }
}

void main() {
  for (final scenario in ['flow', 'late', 'stopFailure']) {
    final lateStart = scenario == 'late';
    final stopFailure = scenario == 'stopFailure';
    testWidgets(
        stopFailure
            ? 'unconfirmed output stop blocks every new guide'
            : lateStart
                ? 'STOP cancels delayed gesture preparation'
                : 'warning preempts voice, fresh target gates resume, missing callback stops voice',
        (t) async {
      t.view.physicalSize = const Size(1800, 2600);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final output = CuePort(), voice = Voice();
      var now = Duration.zero;
      Future<void> flush([int milliseconds = 100]) async {
        now += Duration(milliseconds: milliseconds);
        await t.pump(Duration(milliseconds: milliseconds));
        for (var i = 0; i < 12; i++) {
          await t.pump();
        }
      }

      await t.pumpWidget(MaterialApp(
          home: DoorApproachDemoPage(
              output: output, tts: voice, sessionNow: () => now)));
      await t.tap(find.text('새 장애물 전체 스냅샷 모의 재생'));
      await flush();
      await t.tap(find.text('새 목표 비콘 관측 모의 재생'));
      await flush();
      if (lateStart) output.preparing = Completer();
      await t.tap(find.text('안내 시작'));
      await flush();
      if (stopFailure) {
        final count = voice.spoken.length;
        output.failStop = true;
        await t.tap(find.text('STOP'));
        await flush();
        expect(find.textContaining('출력 실패'), findsOneWidget);
        expect(find.text('상태: stopped'), findsOneWidget);
        await t.tap(find.text('안내 시작'));
        await flush();
        expect(voice.spoken.length, count);
      } else if (lateStart) {
        await t.tap(find.text('STOP'));
        output.preparing!.complete();
        await flush();
        expect(voice.spoken, isEmpty);
        expect(find.text('상태: stopped'), findsOneWidget);
      } else {
        expect(voice.spoken.last, contains('접근 중'));
        final stops = voice.stops;
        await t.tap(find.text('모의 위험: none'));
        await t.pump();
        await t.tap(find.text('모의 위험: danger').last);
        await flush();
        expect(voice.stops, greaterThan(stops));
        expect(voice.spoken.last, contains('위험'));
        expect(output.directions.last, TestDirection.center);
        await t.tap(find.text('새 목표 비콘 관측 모의 재생'));
        await flush();
        await t.tap(find.text('모의 위험: danger'));
        await t.pump();
        await t.tap(find.text('모의 위험: none').last);
        await flush();
        expect(find.text('상태: awaitingTarget'), findsOneWidget);
        final count = voice.spoken.where((x) => x.contains('접근 중')).length;
        await flush(500);
        expect(voice.spoken.where((x) => x.contains('접근 중')).length, count);
        await t.tap(find.text('새 목표 비콘 관측 모의 재생'));
        await flush();
        expect(voice.spoken.last, contains('접근 중'));
        await t.tap(find.text('새 목표 비콘 관측 모의 재생'));
        await flush(3100);
        expect(find.text('상태: unavailable'), findsOneWidget);
        expect(voice.spoken.last, contains('탑승 위치를 다시 확인'));
      }
      await t.pumpWidget(const SizedBox());
      await flush();
      expect(t.takeException(), isNull);
    });
  }
}
