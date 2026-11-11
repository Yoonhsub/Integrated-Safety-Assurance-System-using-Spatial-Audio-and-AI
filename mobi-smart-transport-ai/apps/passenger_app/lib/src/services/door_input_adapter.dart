import 'dart:convert';
import 'package:mobi_mobile_sensors/mobi_mobile_sensors.dart';
import 'door_approach_guard.dart';

/// Converts callback capture time once; repeated UI ticks never refresh a sample.
class DoorBeaconInput {
  DoorBeaconInput(this.guard);
  final DoorApproachGuard guard;
  final Map<String, DateTime> _watermarks = {};
  bool observe(BeaconSignal signal,
      {required DateTime wallNow, required Duration now}) {
    final age = wallNow.difference(signal.lastDetectedAt);
    final previous = _watermarks[signal.beaconId];
    if (age.isNegative ||
        age >= guard.targetTtl ||
        age > now ||
        (previous != null && !signal.lastDetectedAt.isAfter(previous))) {
      return false;
    }
    _watermarks[signal.beaconId] = signal.lastDetectedAt;
    return guard.observeTarget(
        id: signal.beaconId,
        at: now - age,
        now: now,
        proximity: switch (signal.signalLevel) {
          BeaconSignalLevel.veryClose ||
          BeaconSignalLevel.close =>
            DoorProximity.near,
          BeaconSignalLevel.medium ||
          BeaconSignalLevel.far =>
            DoorProximity.approaching,
          BeaconSignalLevel.lost => DoorProximity.unknown,
        });
  }
}

/// One explicit playback of an existing vision-contract snapshot. Its historical
/// capturedAt is retained as evidence, not represented as a live camera capture.
/// Risk is supplied by the operator because the detector contract has no risk.
class DoorVisionReplay {
  DoorVisionReplay._(
      this.frameId, this.capturedAt, this.originalSource, this.obstacles);
  final String frameId;
  final String? capturedAt;
  final String originalSource;
  final List<DoorObstacle> obstacles;
  static DoorVisionReplay parse(String text, {required DoorRisk testRisk}) {
    if (text.length > 65536) throw const FormatException('탐지 JSON 크기 초과');
    final data = jsonDecode(text);
    if (data is! Map ||
        data['schemaVersion'] != '1.0.0' ||
        data['status'] != 'ok' ||
        data['frameId'] is! String ||
        (data['frameId'] as String).trim().isEmpty ||
        data['source'] is! String ||
        data['detections'] is! List ||
        (data['detections'] as List).length > 64 ||
        (data['capturedAt'] != null &&
            (data['capturedAt'] is! String ||
                DateTime.tryParse(data['capturedAt']) == null))) {
      throw const FormatException('정상 탐지 전체 스냅샷이 필요합니다');
    }
    final obstacles = <DoorObstacle>[];
    var index = 0;
    for (final detection in data['detections'] as List) {
      if (detection is! Map ||
          detection['classId'] is! String ||
          (detection['classId'] as String).trim().isEmpty ||
          !_unit(detection['confidence'])) {
        throw const FormatException('탐지 항목 오류');
      }
      final box = detection['bbox'];
      double? pan;
      if (box != null) {
        if (box is! Map ||
            !['x', 'y', 'w', 'h'].every((k) => _unit(box[k])) ||
            box['w'] <= 0 ||
            box['h'] <= 0 ||
            box['x'] + box['w'] > 1.000001 ||
            box['y'] + box['h'] > 1.000001) {
          throw const FormatException('정규화 화면 좌표 오류');
        }
        final center = (box['x'] as num) + (box['w'] as num) / 2;
        pan = center < 1 / 3
            ? -1
            : center > 2 / 3
                ? 1
                : 0;
      }
      // A detected object never silently becomes a clear scene via risk=none.
      if (testRisk == DoorRisk.none) {
        throw const FormatException('탐지 항목에는 모의 caution/danger 위험도를 지정하세요');
      }
      obstacles.add(DoorObstacle('${detection['classId']}#${index++}', testRisk,
          pan: pan));
    }
    return DoorVisionReplay._(data['frameId'], data['capturedAt'],
        data['source'], List.unmodifiable(obstacles));
  }

  static bool _unit(dynamic value) =>
      value is num && value.isFinite && value >= 0 && value <= 1;
}
