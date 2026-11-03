import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobi_mobile_auth/mobile_auth.dart';
import 'package:mobi_passenger_app/local_vision_main.dart' as camera_app;
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:mobi_passenger_app/src/widgets/vision_observation_panel.dart';
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_passenger_app/src/local_vision/frame_pump.dart';
import 'package:mobi_passenger_app/src/local_vision/vision_codec.dart';

VisionFrame frame(int ticks, {int rotation = 0, bool mirror = false}) =>
    VisionFrame(
        width: 2,
        height: 2,
        format: 'bgra8888',
        planes: [
          FramePlane(
              Uint8List.fromList([
                0,
                0,
                255,
                255,
                0,
                255,
                0,
                255,
                255,
                0,
                0,
                255,
                255,
                255,
                255,
                255
              ]),
              8,
              4)
        ],
        rotation: rotation,
        mirror: mirror,
        receivedAt: DateTime.utc(2026, 10, 14),
        receivedMicros: ticks);
LocalObservation observation(VisionFrame f) =>
    LocalObservation(f, Uint8List(0), [], 2, 2, 1, 2);
Future<void> flush() => Future<void>.delayed(Duration.zero);

void main() {
  Map<String, dynamic> binding() => {
        'producerId': 'local-producer',
        'sourceType': 'android_camera',
        'bindingId': 'binding',
        'cameraEpoch': 'epoch',
        'cameraId': 'camera',
        'sessionId': 'session'
      };
  test(
      'Dart producer sends immutable retry body and restores Preview after 503',
      () async {
    final bodies = <String>[];
    var fail = true;
    final sender = DartVisionProducerClient(
        baseUrl: 'http://127.0.0.1:8000',
        producerUid: 'local-producer',
        binding: binding(),
        authClient: AuthenticatedApiClient(
            tokenLoader: ({bool forceRefresh = false}) async => 'test-only',
            client: MockClient((request) async {
              bodies.add(request.body);
              if (fail) return http.Response('{}', 503);
              final body = jsonDecode(request.body);
              return http.Response(
                  jsonEncode({
                    'visionEventId': body['visionEventId'],
                    'bindingId': 'binding',
                    'stored': false,
                    'guidanceEligible': false
                  }),
                  202);
            })));
    await expectLater(
        sender.submit(observation(frame(1))),
        throwsA(isA<VisionProducerException>().having(
            (e) => e.message, 'server failure', contains('Backend 연결 실패'))));
    expect(sender.hasPending, true);
    fail = false;
    await sender.retryPending();
    expect(bodies.length, 2);
    expect(bodies[0], bodies[1]);
    expect(sender.submitted, 1);
    expect(sender.hasPending, false);
    sender.close();
    await expectLater(sender.submit(observation(frame(2))),
        throwsA(isA<VisionProducerException>()));
  });
  test(
      'FramePump stop during HTTP completion discards late display and pending frame',
      () async {
    final sent = Completer<void>();
    var calls = 0;
    final pump =
        FramePump((f) async => observation(f), () => 100, onResult: (_) {
      calls++;
      return sent.future;
    });
    pump.start();
    pump.submit(frame(1));
    await flush();
    pump.submit(frame(2));
    final stopped = pump.stop();
    sent.complete();
    await stopped;
    expect(calls, 1);
    expect(pump.observation, isNull);
    expect(pump.active, false);
    pump.dispose();
  });
  test(
      'FramePump network failure stops without retrying or accumulating frames',
      () async {
    var calls = 0;
    final pump =
        FramePump((f) async => observation(f), () => 100, onResult: (_) async {
      calls++;
      throw const VisionProducerException('연결 실패');
    });
    pump.start();
    pump.submit(frame(1));
    await flush();
    pump.submit(frame(2));
    await flush();
    expect(calls, 1);
    expect(pump.active, false);
    expect(pump.error, '연결 실패');
    expect(pump.observation, isNull);
    pump.dispose();
  });

  test(
      'Android wire fixtures use upright non-square geometry after rotation and mirror',
      () {
    final entries = <Map<String, Object?>>[];
    for (final rotation in [0, 90, 180, 270]) {
      for (final mirror in [false, true]) {
        final f = VisionFrame(
            width: 4,
            height: 2,
            format: 'bgra8888',
            planes: [
              FramePlane(
                  Uint8List.fromList(
                      List.generate(32, (i) => i % 4 == 3 ? 255 : 100)),
                  16,
                  4)
            ],
            rotation: rotation,
            mirror: mirror,
            receivedAt: DateTime.now().toUtc(),
            receivedMicros: 0);
        final prepared = prepareFrame(f);
        expect(prepared.image.width, rotation == 90 || rotation == 270 ? 2 : 4);
        expect(
            prepared.image.height, rotation == 90 || rotation == 270 ? 4 : 2);
        // Explicit SYNTHETIC tensor/box fixture; no camera or model inference.
        final tensor = Float32List.fromList([.5, .5, .25, .25, .9, 0]);
        final boxes = decodeBoxes(tensor, prepared, candidates: 1);
        final result = LocalObservation(f.metadata(), Uint8List(0), boxes,
                prepared.image.width, prepared.image.height, 1, 1)
            .toDetectionResult();
        expect(result['source'], 'android_camera');
        for (final b in boxes) {
          final vertical = rotation == 90 || rotation == 270;
          expect(b.x, closeTo(vertical ? .25 : .375, 1e-6));
          expect(b.y, closeTo(vertical ? .375 : .25, 1e-6));
          expect(b.w, closeTo(vertical ? .5 : .25, 1e-6));
          expect(b.h, closeTo(vertical ? .25 : .5, 1e-6));
          expect(b.x + b.w, lessThanOrEqualTo(1));
          expect(b.y + b.h, lessThanOrEqualTo(1));
        }
        entries.add({
          'rotation': rotation,
          'mirror': mirror,
          'rawSize': {'width': 4, 'height': 2},
          'detectionResult': result
        });
      }
    }
    final path = Platform.environment['MOBI_ANDROID_SOURCE_FIXTURES'];
    if (path != null) {
      File(path).writeAsStringSync(jsonEncode({
        'provenance':
            'SYNTHETIC_PIXELS_AND_TENSOR_ACTUAL_DART_CODEC_NO_DEVICE_NO_INFERENCE',
        'frames': entries
      }));
    }
  });
  test('local camera entry rejects a build without explicit isolation', () {
    expect(camera_app.main, throwsStateError);
  });
  test('DetectionResult preserves UUID, source time and exact model metadata',
      () {
    final f = frame(0);
    expect(f.metadata().frameId, f.frameId);
    final value = LocalObservation(
        f.metadata(),
        Uint8List(0),
        [
          const LocalBox('bus', .9, .1, .2, .3, .4),
          const LocalBox('bus_door', .7, .5, .2, .1, .3)
        ],
        2,
        2,
        12,
        17);
    final json = value.toDetectionResult();
    expect(json['source'], 'android_camera');
    expect(json['status'], 'ok');
    expect(json['capturedAt'], f.receivedAt.toIso8601String());
    expect(
        (json['modelInfo'] as Map)['identifier'], 'sha256:$busDoorModelHash');
    expect(json.containsKey('guidanceEligible'), false);
    expect((json['detections'] as List).map((d) => d['className']),
        ['버스', '버스 문']);
    final evidence = Platform.environment['MOBI_ANDROID_SCHEMA_EVIDENCE'];
    if (evidence != null) {
      File(evidence).writeAsStringSync(jsonEncode([
        json,
        observation(f).toDetectionResult(),
        for (final rotation in [0, 90, 180, 270])
          observation(frame(0, rotation: rotation)).toDetectionResult(),
      ]));
    }
  });
  test('empty frame is valid detection output without a fabricated event', () {
    final result = observation(frame(0)).toDetectionResult();
    expect(result['detections'], isEmpty);
    expect(result.containsKey('safetyEvent'), false);
  });
  for (final box in [
    const LocalBox('person', .9, 0, 0, .1, .1),
    const LocalBox('bus', 1.1, 0, 0, .1, .1),
    const LocalBox('bus', .8, .9, 0, .2, .1),
    const LocalBox('bus', .8, 0, 0, 0, .1),
    const LocalBox('bus', double.nan, 0, 0, .1, .1),
  ]) {
    test(
        'reject unsupported class, confidence or bbox ${box.classId}/${box.confidence}/${box.w}',
        () {
      final value = LocalObservation(frame(0), Uint8List(0), [box], 2, 2, 1, 2);
      expect(value.toDetectionResult, throwsFormatException);
    });
  }
  test('duplicate, reordered and future frames cannot create extra inference',
      () async {
    var now = 10, calls = 0;
    final pump = FramePump((f) async {
      calls++;
      return observation(f);
    }, () => now);
    addTearDown(pump.dispose);
    pump.start();
    final f = frame(10);
    pump.submit(f);
    await flush();
    pump.submit(f);
    pump.submit(frame(9));
    pump.submit(frame(11));
    await flush();
    expect(calls, 1);
    expect(pump.rejected, 3);
    await pump.stop();
    now = 12;
    pump.start();
    pump.submit(frame(12));
    await flush();
    expect(calls, 2);
    await pump.stop();
  });
  test('same timestamps but different frame UUID cannot replace observation',
      () async {
    final pump = FramePump((_) async => observation(frame(0)), () => 0);
    addTearDown(pump.dispose);
    pump.start();
    pump.submit(frame(0));
    await flush();
    expect(pump.observation, isNull);
    expect(pump.error, isNotNull);
    await pump.stop();
  });
  testWidgets(
      'local observation details do not initialize server polling or speech',
      (tester) async {
    final value = LocalObservation(frame(0), Uint8List(0),
        [const LocalBox('bus', .9, .1, .1, .2, .2)], 2, 2, 1, 2);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: VisionObservationPanel.localCamera(value))));
    expect(find.textContaining('guidanceEligible=false'), findsOneWidget);
    expect(find.textContaining('bbox ['), findsOneWidget);
    expect(find.textContaining('android'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  test('wrong/LFS-pointer model bytes fail before native runtime', () {
    expect(
        () => verifyModel(Uint8List.fromList(
            'version https://git-lfs.github.com/spec/v1'.codeUnits)),
        throwsFormatException);
    expect(() => verifyModel(Uint8List(0)), throwsFormatException);
  });
  test('BGRA is RGB float32, padding114 and normalized', () {
    final p = prepareFrame(frame(0));
    final pixel = p.image.getPixel(0, 0);
    expect([pixel.r, pixel.g, pixel.b], [255, 0, 0]);
    expect(p.tensor.length, 640 * 640 * 3);
    expect(p.tensor.take(3), [1, 0, 0]);
  });
  test('rotation and mirror transform pixels before model/display', () {
    final rotated = prepareFrame(frame(0, rotation: 90)).image;
    final red = rotated.getPixel(1, 0);
    expect([red.r, red.g, red.b], [255, 0, 0]);
    final mirrored =
        prepareFrame(frame(0, rotation: 90, mirror: true)).image.getPixel(0, 0);
    expect([mirrored.r, mirrored.g, mirrored.b], [255, 0, 0]);
    for (final rotation in [0, 90, 180, 270]) {
      expect(prepareFrame(frame(0, rotation: rotation)).image.width, 2);
    }
    expect(frameRotation(90, 90, false), 0);
    expect(frameRotation(90, 90, true), 180);
  });
  test('YUV420 row/pixel stride and NV21 padding agree on white', () {
    final y =
        FramePlane(Uint8List.fromList([235, 235, 0, 0, 235, 235, 0, 0]), 4, 1);
    final chroma = FramePlane(Uint8List.fromList([128, 0]), 2, 2);
    final f = VisionFrame(
        width: 2,
        height: 2,
        format: 'yuv420',
        planes: [y, chroma, chroma],
        rotation: 0,
        mirror: false,
        receivedAt: DateTime.utc(2026),
        receivedMicros: 0);
    final nv = VisionFrame(
        width: 2,
        height: 2,
        format: 'nv21',
        planes: [
          FramePlane(
              Uint8List.fromList(
                  [235, 235, 0, 0, 235, 235, 0, 0, 128, 128, 0, 0]),
              4,
              1)
        ],
        rotation: 0,
        mirror: false,
        receivedAt: f.receivedAt,
        receivedMicros: 0);
    for (final source in [f, nv]) {
      final p = prepareFrame(source).image.getPixel(1, 1);
      expect([p.r, p.g, p.b], [255, 255, 255]);
    }
  });
  test('unsupported plane/stride fails rather than corrupted inference', () {
    final f = VisionFrame(
        width: 2,
        height: 2,
        format: 'yuv420',
        planes: [FramePlane(Uint8List(1), 4, 1)],
        rotation: 0,
        mirror: false,
        receivedAt: DateTime.utc(2026),
        receivedMicros: 0);
    expect(() => prepareFrame(f), throwsFormatException);
    expect(() => prepareFrame(frame(0, rotation: 45)), throwsFormatException);
  });
  test('normalized output maps bus and door independently; classwise NMS', () {
    final p = prepareFrame(frame(0));
    final out =
        Float32List.fromList([.5, .5, .5, .5, .4, .4, .4, .4, .9, .8, .8, .7]);
    final boxes = decodeBoxes(out, p, candidates: 2);
    expect(boxes.map((b) => b.classId), ['bus', 'bus_door']);
    expect(boxes.first.x, closeTo(.3, 1e-6));
    expect(boxes.first.w, closeTo(.4, 1e-6));
    expect(() => decodeBoxes(Float32List(5), p, candidates: 1),
        throwsFormatException);
    out[8] = double.nan;
    expect(() => decodeBoxes(out, p, candidates: 2), throwsFormatException);
  });
  test('model pixel placement agrees with Python tie-to-even', () {
    expect(roundModelPixel(158.5), 158);
    expect(roundModelPixel(159.5), 160);
  });
  test('odd letterbox full image bbox restores actual integer padding', () {
    final f = VisionFrame(
        width: 200,
        height: 101,
        format: 'bgra8888',
        planes: [FramePlane(Uint8List(200 * 101 * 4), 200 * 4, 4)],
        rotation: 0,
        mirror: false,
        receivedAt: DateTime.utc(2026),
        receivedMicros: 0);
    final p = prepareFrame(f), rh = (101 * p.scaleY).round();
    final out =
        Float32List.fromList([.5, (p.padY + rh / 2) / 640, 1, rh / 640, .9, 0]);
    final b = decodeBoxes(out, p, candidates: 1).single;
    expect(b.x, closeTo(0, 1e-6));
    expect(b.y, closeTo(0, 1e-6));
    expect(b.w, closeTo(1, 1e-6));
    expect(b.h, closeTo(1, 1e-6));
  });
  test('latest only; one inference in flight and pending replace', () async {
    var now = 0;
    final calls = <VisionFrame>[];
    final pending = <Completer<LocalObservation>>[];
    final pump = FramePump((f) {
      calls.add(f);
      final c = Completer<LocalObservation>();
      pending.add(c);
      return c.future;
    }, () => now);
    addTearDown(pump.dispose);
    pump.start();
    pump.submit(frame(0));
    now = 1;
    pump.submit(frame(1));
    now = 2;
    pump.submit(frame(2));
    expect(calls.length, 1);
    expect(pump.replaced, 1);
    pending[0].complete(observation(calls[0]));
    await flush();
    expect(calls.map((f) => f.receivedMicros), [0, 2]);
    pending[1].complete(observation(calls[1]));
    await flush();
    expect(pump.observation!.frame.receivedMicros, 2);
    await pump.stop();
  });
  test('stop/logout/session disposal never publishes in-flight result',
      () async {
    final pending = Completer<LocalObservation>();
    final pump = FramePump((_) => pending.future, () => 0);
    addTearDown(pump.dispose);
    pump.start();
    final f = frame(0);
    pump.submit(f);
    final stop = pump.stop();
    expect(pump.observation, isNull);
    expect(pump.active, isFalse);
    pending.complete(observation(f));
    await stop;
    expect(pump.observation, isNull);
    pump.start();
    await pump.stop();
  });
  test(
      'completion never retimes stale frame; observation expires without new input',
      () async {
    var now = 0;
    final pending = Completer<LocalObservation>();
    final pump = FramePump((_) => pending.future, () => now);
    addTearDown(pump.dispose);
    pump.start();
    final f = frame(0);
    pump.submit(f);
    now = 2100000;
    pending.complete(observation(f));
    await flush();
    expect(pump.observation, isNull);
    expect(pump.expired, 1);
    await pump.stop();
    now = 0;
    final fresh = FramePump((f) async => observation(f), () => now);
    addTearDown(fresh.dispose);
    fresh.start();
    fresh.submit(frame(0));
    await flush();
    expect(fresh.observation, isNotNull);
    now = 2100000;
    fresh.expire();
    expect(fresh.lost, isTrue);
    expect(fresh.observation, isNull);
    await fresh.stop();
  });
  test('inference error clears local state and stops accepting frames',
      () async {
    final pump = FramePump((_) async => throw StateError('runtime'), () => 0);
    addTearDown(pump.dispose);
    pump.start();
    pump.submit(frame(0));
    await flush();
    expect(pump.active, isFalse);
    expect(pump.error, isNotNull);
    expect(pump.observation, isNull);
    await pump.stop();
  });
  test('invalid row stride is rejected even when the whole plane is large', () {
    final f = VisionFrame(
        width: 2,
        height: 2,
        format: 'yuv420',
        planes: [
          FramePlane(Uint8List(20), 1, 1),
          FramePlane(Uint8List(20), 2, 1),
          FramePlane(Uint8List(20), 2, 1)
        ],
        rotation: 0,
        mirror: false,
        receivedAt: DateTime.utc(2026),
        receivedMicros: 0);
    expect(() => prepareFrame(f), throwsFormatException);
  });
  test('worker result from another frame is never displayed', () async {
    final pump = FramePump((_) async => observation(frame(99)), () => 100);
    addTearDown(pump.dispose);
    pump.start();
    pump.submit(frame(0));
    await flush();
    expect(pump.error, isNotNull);
    expect(pump.observation, isNull);
    await pump.stop();
  });
}
