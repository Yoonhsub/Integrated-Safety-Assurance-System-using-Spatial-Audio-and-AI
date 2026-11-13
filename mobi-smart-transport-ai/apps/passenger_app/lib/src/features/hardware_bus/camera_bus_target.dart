import 'dart:math' as math;
import '../../local_vision/vision_codec.dart';
import 'wit_sensor_protocol.dart';

class CameraHeadingSample {
  const CameraHeadingSample(this.degrees, this.at, {this.usable = true});
  final double degrees;
  final DateTime at;
  final bool usable;
  bool fresh(DateTime now) =>
      usable &&
      degrees.isFinite &&
      !now.difference(at).isNegative &&
      now.difference(at) < const Duration(milliseconds: 300);
}

/// Local diagnostic only: visual target is manually associated with the beacon.
/// Camera heading and head yaw have independent zero offsets, set while both
/// point at the same marker. Capture-time phone attitude avoids double rotation.
class CameraBusTargetTracker {
  final List<CameraHeadingSample> _phone = [];
  double? _phoneZero, _headZero, _worldBearing;
  DateTime? _capturedAt;
  String? _frameId;
  double fov = 60;
  bool reverseHead = false;
  String reason = '동일 정면 기준 설정 필요';
  bool get calibrated => _phoneZero != null && _headZero != null;
  void addPhone(CameraHeadingSample sample) {
    _phone.add(sample);
    if (_phone.length > 120) _phone.removeAt(0);
  }

  void reset() {
    _phoneZero = _headZero = null;
    clear('동일 정면 기준 재설정 필요');
  }

  void clear(String message) {
    _worldBearing = null;
    _capturedAt = null;
    reason = message;
  }

  bool calibrate(double yaw, DateTime now) {
    if (_phone.isEmpty ||
        !_phone.last.fresh(now) ||
        !yaw.isFinite ||
        !fov.isFinite ||
        fov < 20 ||
        fov > 130) {
      return false;
    }
    _phoneZero = _phone.last.degrees;
    _headZero = yaw;
    _frameId = null;
    clear('카메라의 단일 버스 문 확인 대기');
    return true;
  }

  void observe(LocalObservation frame, DateTime now) {
    final at = frame.frame.receivedAt.toUtc();
    final age = now.difference(at);
    if (!calibrated ||
        age.isNegative ||
        age >= const Duration(seconds: 1) ||
        frame.frame.mirror ||
        frame.modelHash != unifiedV4ModelHash) {
      clear('유효한 후면 카메라 프레임·기준 필요');
      return;
    }
    if (_frameId == frame.frame.frameId) return;
    _frameId = frame.frame.frameId;
    if (_capturedAt != null && !at.isAfter(_capturedAt!)) {
      clear('카메라 프레임 순서 오류');
      return;
    }
    final buses = frame.boxes
        .where((b) => b.classId == 'bus' && b.confidence >= .5)
        .toList();
    final doors = frame.boxes
        .where((b) => b.classId == 'bus_door' && b.confidence >= .55)
        .toList();
    if (buses.length != 1 || doors.length != 1) {
      clear('버스 1대·문 1개가 함께 보여야 합니다');
      return;
    }
    final bus = buses.single, door = doors.single;
    bool valid(LocalBox b) =>
        [b.confidence, b.x, b.y, b.w, b.h].every((v) => v.isFinite) &&
        b.confidence <= 1 &&
        b.x >= 0 &&
        b.y >= 0 &&
        b.w > 0 &&
        b.h > 0 &&
        b.x + b.w <= 1.000000001 &&
        b.y + b.h <= 1.000000001;
    if (!valid(bus) || !valid(door)) {
      clear('잘못된 검출 박스');
      return;
    }
    final overlap = math.max(
            0.0,
            math.min(bus.x + bus.w, door.x + door.w) -
                math.max(bus.x, door.x)) *
        math.max(0.0,
            math.min(bus.y + bus.h, door.y + door.h) - math.max(bus.y, door.y));
    if (overlap / (door.w * door.h) < .7) {
      clear('버스 내부 문 확인 불가');
      return;
    }
    final samples = _phone
        .where((p) =>
            p.usable &&
            p.degrees.isFinite &&
            p.at.difference(at).inMilliseconds.abs() <= 250)
        .toList()
      ..sort((a, b) => a.at
          .difference(at)
          .inMicroseconds
          .abs()
          .compareTo(b.at.difference(at).inMicroseconds.abs()));
    if (samples.isEmpty) {
      clear('촬영 시각의 휴대폰 방향 없음');
      return;
    }
    final cameraAngle = math.atan(
            (2 * (door.x + door.w / 2) - 1) * math.tan(fov * math.pi / 360)) *
        180 /
        math.pi;
    _worldBearing =
        relativeAngle(samples.first.degrees, _phoneZero!) + cameraAngle;
    _capturedAt = at;
    reason = '버스 문 실측 추적 중 · 수동 비콘 연결';
  }

  double? angle(DateTime now,
      {required double? headYaw,
      required bool headFresh,
      required bool beaconFresh}) {
    if (!calibrated) {
      reason = '동일 정면 기준 설정 필요';
      return null;
    }
    if (!headFresh || headYaw?.isFinite != true) {
      reason = '머리 센서 수신 상실';
      return null;
    }
    if (!beaconFresh) {
      reason = '목표 비콘 신호 상실';
      return null;
    }
    if (_phone.isEmpty || !_phone.last.fresh(now)) {
      reason = '휴대폰 방향 수신 상실';
      return null;
    }
    if (_worldBearing == null || _capturedAt == null) {
      return null;
    }
    if (now.difference(_capturedAt!).isNegative ||
        now.difference(_capturedAt!) >= const Duration(seconds: 1)) {
      reason = '카메라 관찰 만료';
      return null;
    }
    final head = relativeAngle(headYaw!, _headZero!) * (reverseHead ? -1 : 1);
    return relativeAngle(_worldBearing!, head);
  }
}
