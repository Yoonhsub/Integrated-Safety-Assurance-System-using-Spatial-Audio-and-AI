import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_passenger_app/src/features/hardware_bus/camera_bus_target.dart';
import 'package:mobi_passenger_app/src/local_vision/vision_codec.dart';

void main() {
  final t = DateTime.utc(2026, 11, 13);
  LocalObservation frame(DateTime at,
          {double center = .5,
          List<LocalBox>? boxes,
          String id = 'f1',
          bool mirror = false}) =>
      LocalObservation(
          VisionFrame(
              width: 640,
              height: 480,
              format: 'yuv420',
              planes: [],
              rotation: 0,
              mirror: mirror,
              receivedAt: at,
              receivedMicros: 100,
              frameId: id),
          Uint8List(0),
          boxes ??
              [
                const LocalBox('bus', .9, 0, .1, 1, .8),
                LocalBox('bus_door', .8, center - .04, .3, .08, .3)
              ],
          640,
          480,
          10,
          20);
  CameraBusTargetTracker setup() {
    final a = CameraBusTargetTracker()..fov = 60;
    a.addPhone(CameraHeadingSample(10, t));
    expect(a.calibrate(100, t), true);
    return a;
  }

  double? angle(CameraBusTargetTracker a, DateTime now,
          {double yaw = 100, bool head = true, bool beacon = true}) =>
      a.angle(now, headYaw: yaw, headFresh: head, beaconFresh: beacon);
  test('neutral calibration needs no camera geometry or detected objects', () {
    final a = CameraBusTargetTracker();
    a.addPhone(CameraHeadingSample(0, t));
    expect(a.calibrate(0, t), true);
    a.observe(frame(t), t);
    expect(angle(a, t, yaw: 0), isNull);
    expect(a.calibrated, true);
    a.fov = 60;
    a.observe(frame(t, id: 'with-fov'), t);
    expect(angle(a, t, yaw: 0), closeTo(0, 1e-8));
  });
  test('camera target left center right moves sound with stationary head', () {
    final a = setup();
    a.observe(frame(t, center: .2), t);
    expect(angle(a, t), lessThan(0));
    a.observe(frame(t.add(const Duration(milliseconds: 50)), id: 'f2'),
        t.add(const Duration(milliseconds: 50)));
    expect(angle(a, t.add(const Duration(milliseconds: 50))), closeTo(0, 1e-8));
    a.observe(
        frame(t.add(const Duration(milliseconds: 100)), center: .8, id: 'f3'),
        t.add(const Duration(milliseconds: 100)));
    expect(angle(a, t.add(const Duration(milliseconds: 100))), greaterThan(0));
  });
  test('handheld camera rotation and head rotation are independent', () {
    final a = setup();
    final now = t.add(const Duration(milliseconds: 100));
    a.addPhone(CameraHeadingSample(40, now));
    a.observe(frame(now), now);
    expect(angle(a, now), closeTo(30, 1e-8));
    expect(angle(a, now, yaw: 130), closeTo(0, 1e-8));
    expect(angle(a, now, yaw: 150), closeTo(-20, 1e-8));
  });
  test(
      'capture-time heading is used rather than post-inference phone direction',
      () {
    final a = setup();
    a.addPhone(
        CameraHeadingSample(70, t.add(const Duration(milliseconds: 200))));
    a.observe(frame(t), t.add(const Duration(milliseconds: 200)));
    expect(
        angle(a, t.add(const Duration(milliseconds: 200))), closeTo(0, 1e-8));
  });
  test('sensor and beacon are mandatory; phone stream loss and frame age stop',
      () {
    final a = setup();
    a.observe(frame(t), t);
    expect(angle(a, t, head: false), isNull);
    expect(angle(a, t, beacon: false), isNull);
    expect(angle(a, t.add(const Duration(milliseconds: 301))), isNull);
    a.addPhone(CameraHeadingSample(10, t.add(const Duration(seconds: 1))));
    expect(angle(a, t.add(const Duration(seconds: 1))), isNull);
  });
  test('no bus clears target; ambiguous doors use bus center', () {
    final a = setup();
    a.observe(frame(t), t);
    expect(angle(a, t), isNotNull);
    final next = t.add(const Duration(milliseconds: 50));
    a.observe(frame(next, boxes: [], id: 'none'), next);
    expect(angle(a, next), isNull);
    a.observe(frame(next.add(const Duration(milliseconds: 10)), id: 'again'),
        next.add(const Duration(milliseconds: 10)));
    expect(angle(a, next.add(const Duration(milliseconds: 10))), isNotNull);
    a.observe(
        frame(next.add(const Duration(milliseconds: 20)), id: 'two', boxes: [
          const LocalBox('bus', .9, 0, .1, 1, .8),
          const LocalBox('bus_door', .8, .2, .3, .08, .3),
          const LocalBox('bus_door', .8, .6, .3, .08, .3)
        ]),
        next.add(const Duration(milliseconds: 20)));
    expect(angle(a, next.add(const Duration(milliseconds: 20))), isNotNull);
  });
  test('bus-only frame produces direction but never claims door position', () {
    final a = setup();
    a.observe(frame(t, boxes: [const LocalBox('bus', .9, .6, .1, .3, .8)]), t);
    expect(angle(a, t), greaterThan(0));
    expect(a.reason, contains('문 위치 안내 아님'));
    final next = t.add(const Duration(milliseconds: 50));
    a.observe(
        frame(next, id: 'multi', boxes: [
          const LocalBox('bus', .9, .1, .1, .3, .8),
          const LocalBox('bus', .9, .6, .1, .3, .8)
        ]),
        next);
    expect(angle(a, next), isNull);
  });
  test('front camera and future frames are rejected', () {
    final a = setup();
    a.observe(frame(t, mirror: true), t);
    expect(angle(a, t), isNull);
    a.observe(frame(t.add(const Duration(seconds: 1))), t);
    expect(angle(a, t), isNull);
  });
  test('calibration reset requires new frame and head sign is configurable',
      () {
    final a = setup();
    a.reverseHead = true;
    a.observe(frame(t), t);
    expect(angle(a, t, yaw: 130), closeTo(30, 1e-8));
    a.reset();
    expect(angle(a, t), isNull);
  });
}
