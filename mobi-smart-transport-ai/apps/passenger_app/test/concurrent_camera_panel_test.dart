import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_passenger_app/src/features/hardware_bus/concurrent_camera_panel.dart';
import 'package:mobi_passenger_app/src/local_vision/vision_codec.dart';
import 'package:mobi_passenger_app/src/services/directional_guidance.dart';
import 'package:mobi_passenger_app/src/services/spatial_verification_engine.dart';
import 'package:mobi_passenger_app/src/services/speech_priority_coordinator.dart';

class Source extends ConcurrentCameraSource {
  @override
  bool running = false;
  @override
  bool starting = false;
  @override
  String status = 'fake camera';
  @override
  LocalObservation? observation;
  int starts = 0, stops = 0;
  @override
  Future<void> start() async {
    starts++;
    running = true;
    notifyListeners();
  }

  @override
  Future<void> stop() async {
    stops++;
    running = false;
    observation = null;
    notifyListeners();
  }

  void emit(
      {bool empty = false,
      bool stale = false,
      List<LocalBox>? boxes,
      DateTime? receivedAt,
      double inferenceMs = 1,
      Uint8List? jpeg}) {
    final now = receivedAt ??
        DateTime.now().toUtc().subtract(Duration(seconds: stale ? 3 : 0));
    observation = LocalObservation(
        VisionFrame(
            width: 16,
            height: 16,
            format: 'nv21',
            planes: [],
            rotation: 0,
            mirror: false,
            receivedAt: now,
            receivedMicros: 1),
        jpeg ?? Uint8List(0),
        empty ? [] : boxes ?? [const LocalBox('pole', .9, .1, .1, .1, .4)],
        16,
        16,
        inferenceMs,
        1);
    notifyListeners();
  }
}

class Output
    implements
        SpatialTestOutput,
        DirectionalCueOutput,
        InformationalDirectionalCueOutput {
  final cues = <TestDirection>[];
  @override
  Future<void> prepareFromGesture() async {}
  @override
  Future<bool> play(String mode, String direction) async => true;
  @override
  Future<bool> playCue(TestDirection direction) async {
    cues.add(direction);
    return true;
  }

  @override
  Future<bool> playInformationalCue(
          TestDirection direction, InformationalCueTone tone) =>
      playCue(direction);
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
  @override
  Map<String, dynamic> snapshot() => {};
}

class Speech implements SpeechEngine {
  final spoken = <String>[];
  Completer<void>? hold;
  @override
  Future<void> prepare({required bool requireKoreanVoice}) async {}
  @override
  Future<void> speak(String text) async {
    spoken.add(text);
    await hold?.future;
  }

  @override
  Future<void> stop() async {
    if (hold?.isCompleted == false) hold!.complete();
  }
}

class FailingStopPriority extends SpeechPriorityCoordinator {
  FailingStopPriority(super.engine);
  @override
  Future<void> stopObservation(Object owner) async =>
      throw StateError('stop failed');
}

void main() {
  late Source source;
  late Output output;
  late Speech speech;
  late SpatialVerificationEngine engine;
  late SpeechPriorityCoordinator priority;
  void initialize() {
    source = Source();
    output = Output();
    speech = Speech();
    engine = SpatialVerificationEngine(output, speech);
    priority = SpeechPriorityCoordinator(engine);
  }

  tearDown(() async {
    priority.dispose();
    await engine.dispose();
    source.dispose();
  });
  Widget panel({ConcurrentObservationPlayer? player, bool compact = false}) =>
      MaterialApp(
          home: Scaffold(
              body: SingleChildScrollView(
                  child: ConcurrentCameraPanel(
                      source: source,
                      engine: engine,
                      priority: priority,
                      isCurrent: () => true,
                      compact: compact,
                      playObservation: player))));
  Future<void> tap(WidgetTester t, String text) async {
    await t.ensureVisible(find.text(text));
    await t.tap(find.text(text));
    await t.pump();
  }

  Future<void> frames(WidgetTester t, {bool stale = false}) async {
    for (var i = 0; i < 3; i++) {
      source.emit(stale: stale);
      await t.pump();
    }
  }

  testWidgets('compact preview uses a readable height', (t) async {
    t.view.physicalSize = const Size(360, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    initialize();
    await t.pumpWidget(panel(compact: true));
    source.emit(
        empty: true,
        jpeg: Uint8List.fromList(base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jMgAAAABJRU5ErkJggg==')));
    await t.pump();
    expect(t.getSize(find.byType(Image).last).height, 180);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });

  for (final parent in ['absent', 'outside', 'valid']) {
    testWidgets('diagnostic door requires verified parent bus: $parent',
        (t) async {
      initialize();
      await t.pumpWidget(panel());
      await tap(t, '카메라 시작');
      await tap(t, '화면 위치 소리 시작');
      final boxes = [
        const LocalBox('bus_door', .99, .1, .2, .15, .4),
        if (parent == 'valid') const LocalBox('bus', .9, .05, .1, .5, .7),
        if (parent == 'outside') const LocalBox('bus', .9, .65, .1, .3, .7),
      ];
      for (var i = 0; i < 3; i++) {
        source.emit(boxes: boxes);
        await t.pump();
      }
      // Detailed speech must obey the same filter, not just automatic cues.
      await t.pump(const Duration(milliseconds: 50));
      if (parent == 'valid') {
        await tap(t, '자세히 듣기');
        await t.pump();
        expect(speech.spoken.any((s) => s.contains('버스 문')), isTrue);
      } else {
        expect(speech.spoken.any((s) => s.contains('버스 문')), isFalse);
      }
      await t.pumpWidget(const SizedBox());
    });
  }

  testWidgets('unverified door cannot hide a current obstacle cue', (t) async {
    initialize();
    await t.pumpWidget(panel());
    await tap(t, '카메라 시작');
    await tap(t, '화면 위치 소리 시작');
    for (var i = 0; i < 3; i++) {
      source.emit(boxes: const [
        LocalBox('bus_door', .99, .1, .1, .2, .6),
        LocalBox('pole', .9, .75, .2, .15, .6),
      ]);
      await t.pump();
    }
    expect(output.cues, [TestDirection.right]);
    expect(speech.spoken.any((s) => s.contains('버스 문')), isFalse);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets(
      'camera is independent; audio defaults off, explicit enable uses screen cue and voice',
      (t) async {
    initialize();
    await t.pumpWidget(panel());
    await tap(t, '카메라 시작');
    await frames(t);
    expect(output.cues, isEmpty);
    expect(source.starts, 1);
    await tap(t, '화면 위치 소리 시작');
    await frames(t);
    await t.pump();
    expect(output.cues, [TestDirection.left]);
    expect(speech.spoken.last, contains('화면 왼쪽'));
    await tap(t, '화면 위치 소리 중지');
    expect(source.running, isTrue);
    expect(source.stops, 0);
    await tap(t, '카메라 중지');
    expect(source.running, isFalse);
    expect(source.stops, 1);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets(
      'ping only never TTS; shared busy callback drops audio without camera stop',
      (t) async {
    initialize();
    var allowed = false, attempts = 0;
    await t.pumpWidget(panel(player: (owner, command, valid) async {
      attempts++;
      if (!allowed) return false;
      return priority.speakObservation(owner, command, valid);
    }));
    await tap(t, '카메라 시작');
    await t.ensureVisible(find.byType(SwitchListTile));
    await t.tap(find.byType(SwitchListTile));
    await t.pump();
    await tap(t, '화면 위치 소리 시작');
    await frames(t);
    expect(attempts, 1);
    expect(output.cues, isEmpty);
    expect(source.running, isTrue);
    await tap(t, '화면 위치 소리 중지');
    allowed = true;
    await tap(t, '화면 위치 소리 시작');
    await frames(t);
    expect(output.cues, [TestDirection.left]);
    expect(speech.spoken, isEmpty);
    expect(source.stops, 0);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets(
      'stale frames never play and background stops camera without autoplay on resume',
      (t) async {
    initialize();
    await t.pumpWidget(panel());
    await tap(t, '카메라 시작');
    await tap(t, '화면 위치 소리 시작');
    await frames(t, stale: true);
    expect(output.cues, isEmpty);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await t.pump();
    expect(source.running, isFalse);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pump();
    expect(source.starts, 1);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets('camera stops even when audio cleanup fails', (t) async {
    initialize();
    priority.dispose();
    priority = FailingStopPriority(engine);
    await t.pumpWidget(panel());
    await tap(t, '카메라 시작');
    await tap(t, '화면 위치 소리 시작');
    await tap(t, '카메라 중지');
    expect(source.running, isFalse);
    expect(source.stops, 1);
    expect(find.textContaining('소리 정지 확인 실패'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    await t.pump();
    expect(t.takeException(), isNull);
  });
  testWidgets('camera audio STOP cannot cancel other owner speech', (t) async {
    initialize();
    await t.pumpWidget(panel());
    await tap(t, '카메라 시작');
    await tap(t, '화면 위치 소리 시작');
    speech.hold = Completer<void>();
    final bus =
        priority.speakObservation(Object(), 'bus announcement', () => true);
    await t.pump();
    await tap(t, '화면 위치 소리 중지');
    expect(speech.hold!.isCompleted, isFalse);
    expect(source.running, isTrue);
    speech.hold!.complete();
    await t.pump();
    expect(await bus, isTrue);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets(
      'multiple positions use grouped speech and never a selected-object ping',
      (t) async {
    initialize();
    await t.pumpWidget(panel());
    await tap(t, '카메라 시작');
    await tap(t, '화면 위치 소리 시작');
    for (var i = 0; i < 3; i++) {
      source.emit(boxes: [
        const LocalBox('pole', .9, .1, .1, .1, .4),
        const LocalBox('tree_trunk', .9, .45, .1, .1, .4),
      ]);
      await t.pump();
      await t.pump();
    }
    expect(output.cues, isEmpty);
    expect(speech.spoken.last, contains('왼쪽과 중앙'));
    expect(speech.spoken.last, contains('장애물'));
    await tap(t, '자세히 듣기');
    await t.pump();
    expect(speech.spoken.last, contains('보도 기둥 1개'));
    expect(speech.spoken.last, contains('나무 줄기 1개'));
    expect(speech.spoken.last, contains('실제 거리'));
    await t.pumpWidget(const SizedBox());
  });
  testWidgets(
      'manual detail works with automatic audio off; stale cannot replay',
      (t) async {
    initialize();
    await t.pumpWidget(panel());
    await tap(t, '카메라 시작');
    await frames(t);
    expect(speech.spoken, isEmpty);
    await tap(t, '자세히 듣기');
    await t.pump();
    expect(speech.spoken.last, contains('보도 기둥 1개'));
    final before = speech.spoken.length;
    source.emit(stale: true);
    await t.pump();
    expect(
        t
            .widget<OutlinedButton>(
                find.widgetWithText(OutlinedButton, '자세히 듣기'))
            .onPressed,
        isNull);
    expect(speech.spoken.length, before);
    expect(find.textContaining('현재 화면을 확인하기 어렵습니다'), findsWidgets);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets(
      'uncertain empty frame never says road clear and no directional ping',
      (t) async {
    initialize();
    await t.pumpWidget(panel());
    await tap(t, '카메라 시작');
    source.emit(empty: true);
    await t.pump();
    await tap(t, '자세히 듣기');
    await t.pump();
    expect(output.cues, isEmpty);
    expect(speech.spoken.last, contains('뜻은 아닙니다'));
    await t.pumpWidget(const SizedBox());
  });
  testWidgets(
      'STOP cancels pending manual detail before shared output admission',
      (t) async {
    initialize();
    final admission = Completer<void>();
    await t.pumpWidget(panel(player: (owner, command, valid) async {
      await admission.future;
      return priority.speakObservation(owner, command, valid);
    }));
    await tap(t, '카메라 시작');
    await frames(t);
    await tap(t, '자세히 듣기');
    await tap(t, '화면 위치 소리 중지');
    admission.complete();
    for (var i = 0; i < 4; i++) {
      await t.pump();
    }
    expect(speech.spoken, isEmpty);
    expect(output.cues, isEmpty);
    expect(source.running, isTrue);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets(
      'automatic cooldown applies across scene changes; explicit detail stays available',
      (t) async {
    initialize();
    await t.pumpWidget(panel());
    await tap(t, '카메라 시작');
    await tap(t, '화면 위치 소리 시작');
    await frames(t);
    await t.pump();
    final count = speech.spoken.length;
    expect(count, 1);
    for (var i = 0; i < 3; i++) {
      source.emit(boxes: [const LocalBox('tree_trunk', .9, .8, .1, .1, .4)]);
      await t.pump();
    }
    expect(speech.spoken.length, count);
    await tap(t, '자세히 듣기');
    await t.pump();
    expect(speech.spoken.length, count + 1);
    expect(speech.spoken.last, contains('오른쪽'));
    await t.pumpWidget(const SizedBox());
  });
  testWidgets('interrupted automatic speech still consumes global cooldown',
      (t) async {
    initialize();
    await t.pumpWidget(panel());
    await tap(t, '카메라 시작');
    await tap(t, '화면 위치 소리 시작');
    speech.hold = Completer<void>();
    await frames(t);
    await t.pump();
    expect(speech.spoken, hasLength(1));
    for (var i = 0; i < 3; i++) {
      source.emit(boxes: [const LocalBox('tree_trunk', .9, .8, .1, .1, .4)]);
      await t.pump();
      await t.pump();
    }
    expect(speech.hold!.isCompleted, isTrue);
    expect(speech.spoken, hasLength(1));
    expect(source.running, isTrue);
    await tap(t, '자세히 듣기');
    await t.pump();
    expect(speech.spoken, hasLength(2));
    expect(speech.spoken.last, contains('오른쪽'));
    await t.pumpWidget(const SizedBox());
  });
  for (final malformed in [true, false]) {
    testWidgets(
        'invalid observation retains receipt ordering, malformed=$malformed',
        (t) async {
      initialize();
      await t.pumpWidget(panel());
      await tap(t, '카메라 시작');
      final latest =
          DateTime.now().toUtc().subtract(const Duration(milliseconds: 100));
      for (var i = 2; i >= 0; i--) {
        source.emit(receivedAt: latest.subtract(Duration(milliseconds: i)));
        await t.pump();
      }
      if (malformed) {
        source.emit(
            receivedAt: latest.add(const Duration(milliseconds: 1)),
            inferenceMs: -1);
      } else {
        source.observation = null;
        source.notifyListeners();
      }
      await t.pump();
      for (var i = 3; i > 0; i--) {
        source.emit(
            receivedAt: latest.subtract(Duration(milliseconds: 10 + i)));
        await t.pump();
      }
      final detail = t.widget<OutlinedButton>(
          find.widgetWithText(OutlinedButton, '자세히 듣기'));
      expect(detail.onPressed, isNull);
      expect(speech.spoken, isEmpty);
      expect(source.running, isTrue);
      await t.pumpWidget(const SizedBox());
    });
  }
}
