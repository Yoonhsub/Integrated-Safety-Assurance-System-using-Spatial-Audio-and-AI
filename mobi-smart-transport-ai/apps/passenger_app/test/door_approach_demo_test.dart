import 'dart:async';
import 'dart:convert';
import 'package:mobi_mobile_sensors/mobi_mobile_sensors.dart';
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

class ScanPort implements BeaconScanner {
  final samples = StreamController<BeaconSignal>.broadcast();
  bool active = false;
  int starts = 0, stops = 0;
  @override
  bool get isScanning => active;
  @override
  Stream<BeaconSignal> scan({String? targetBeaconId}) {
    starts++;
    active = true;
    return samples.stream;
  }

  @override
  Future<void> stop() async {
    stops++;
    active = false;
  }
}

void main() {
  for (final latePermission in [false, true]) {
    testWidgets(
        latePermission
            ? 'STOP invalidates pending BLE permission'
            : 'native BLE expires voice and transport loss stops all guidance without auto resume',
        (t) async {
      t.view.physicalSize = const Size(1800, 3200);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final output = CuePort(), voice = Voice(), scanner = ScanPort();
      final stops = StreamController<void>();
      final permission = Completer<bool>();
      var now = const Duration(seconds: 1);
      final wall = DateTime.utc(2026, 11, 11);
      Future<void> flush([int milliseconds = 100]) async {
        now += Duration(milliseconds: milliseconds);
        await t.pump(Duration(milliseconds: milliseconds));
        for (var i = 0; i < 12; i++) {
          await t.pump();
        }
      }

      await t.pumpWidget(MaterialApp(
          home: DoorApproachDemoPage(
              output: output,
              tts: voice,
              sessionNow: () => now,
              wallNow: () => wall.add(now),
              targetId: 'A',
              scannerFactory: () => scanner,
              transportStops: stops.stream,
              prepareScanner: () =>
                  latePermission ? permission.future : Future.value(true))));
      expect(find.text('새 목표 비콘 관측 모의 재생'), findsNothing);
      await t.tap(find.text('실측 BLE 스캔 시작 (5분)'));
      await flush();
      if (latePermission) {
        await t.tap(find.text('STOP'));
        permission.complete(true);
        await flush();
        expect(scanner.starts, 0);
        expect(voice.spoken, isEmpty);
      } else {
        await t.tap(find.text('새 장애물 전체 스냅샷 모의 재생'));
        await flush();
        await t.tap(find.text('안내 시작'));
        await flush();
        void sample(String id) {
          now += const Duration(milliseconds: 1);
          scanner.samples.add(BeaconSignal(
              beaconId: id,
              rssi: -55,
              estimatedDistanceMeters: null,
              signalLevel: BeaconSignalLevel.close,
              lastDetectedAt: wall.add(now)));
        }

        sample('A');
        await flush();
        expect(voice.spoken.last, contains('문과 발밑'));
        sample('B');
        await flush(3100);
        expect(voice.spoken.last, contains('탑승 위치를 다시 확인'));
        sample('A');
        await flush();
        expect(voice.spoken.last, contains('문과 발밑'));
        stops.add(null);
        await flush();
        expect(find.text('상태: stopped'), findsOneWidget);
        expect(scanner.stops, greaterThan(0));
        final count = voice.spoken.length;
        sample('A');
        await flush();
        expect(voice.spoken.length, count);
      }
      await t.pumpWidget(const SizedBox());
      await t.pump();
      unawaited(scanner.samples.close());
      unawaited(stops.close());
      await t.pump();
    });
  }
  testWidgets(
      'recorded detection reaches left warning and invalid JSON stops output',
      (t) async {
    t.view.physicalSize = const Size(1800, 3200);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    var now = const Duration(seconds: 1);
    final output = CuePort(), voice = Voice();
    Future<void> flush() async {
      now += const Duration(milliseconds: 100);
      await t.pump(const Duration(milliseconds: 100));
      for (var i = 0; i < 12; i++) {
        await t.pump();
      }
    }

    await t.pumpWidget(MaterialApp(
        home: DoorApproachDemoPage(
            output: output, tts: voice, sessionNow: () => now)));
    await t.tap(find.text('안내 시작'));
    await flush();
    await t.tap(find.text('모의 위험: none'));
    await t.pump();
    await t.tap(find.text('모의 위험: danger').last);
    await flush();
    await t.tap(find.text('AI 탐지 JSON 한 프레임 재생'));
    await t.pump(const Duration(milliseconds: 300));
    final json = jsonEncode({
      'schemaVersion': '1.0.0',
      'status': 'ok',
      'source': 'android_camera',
      'frameId': 'recorded-frame',
      'capturedAt': '2026-11-10T00:00:00Z',
      'detections': [
        {
          'classId': 'pole',
          'confidence': .9,
          'bbox': {'x': .1, 'y': .1, 'w': .1, 'h': .5}
        }
      ]
    });
    await t.enterText(find.byType(TextField), json);
    await t.pumpAndSettle();
    await t.ensureVisible(find.text('탐지 스냅샷 1회 재생'));
    await t.pumpAndSettle();
    await t.tap(find.text('탐지 스냅샷 1회 재생'));
    await flush();
    expect(output.directions.last, TestDirection.left);
    expect(voice.spoken.last, contains('위험'));
    expect(find.textContaining('위험도 모의 danger'), findsOneWidget);
    final stops = voice.stops;
    await t.enterText(find.byType(TextField), '{broken');
    await t.pumpAndSettle();
    await t.ensureVisible(find.text('탐지 스냅샷 1회 재생'));
    await t.pumpAndSettle();
    await t.tap(find.text('탐지 스냅샷 1회 재생'));
    await flush();
    expect(find.text('상태: stopped'), findsOneWidget);
    expect(voice.stops, greaterThan(stops));
    await t.pumpWidget(const SizedBox());
    await t.pump();
  });
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
