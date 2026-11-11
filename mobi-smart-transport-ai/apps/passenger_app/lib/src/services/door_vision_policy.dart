import 'dart:convert';
import '../local_vision/vision_codec.dart';
import 'door_approach_guard.dart';
import 'door_input_adapter.dart';

/// Opt-in rehearsal policy, NOT a collision risk or path-clearance estimator.
/// Detected parked PMs, poles and tree trunks receive caution only. No distance,
/// danger, door-open, boarding or free-path assertion is inferred from a box.
class DoorVisionPolicy {
  Duration? _lastCapture;
  final _frames = <String>{};
  List<DoorObstacle> evaluate(Map<String, Object?> result,
      {required Duration capturedAt, required Duration now}) {
    if (capturedAt.isNegative ||
        capturedAt > now ||
        now - capturedAt >= const Duration(seconds: 2) ||
        (_lastCapture != null && capturedAt <= _lastCapture!)) {
      throw const FormatException('카메라 관측 시각 만료/역순');
    }
    if (result['source'] != 'android_camera') {
      throw const FormatException('실측 카메라 입력이 아닙니다');
    }
    final parsed =
        DoorVisionReplay.parse(jsonEncode(result), testRisk: DoorRisk.caution);
    if (parsed.capturedAt == null || !_frames.add(parsed.frameId)) {
      throw const FormatException('카메라 프레임 식별 정보 누락/중복');
    }
    _lastCapture = capturedAt;
    if (_frames.length > 128) _frames.remove(_frames.first);
    final obstacles = <DoorObstacle>[];
    final rows = result['detections'] as List;
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i] as Map;
      final threshold = unifiedV4Thresholds[row['classId']];
      if (threshold == null || (row['confidence'] as num) < threshold) {
        throw const FormatException('알 수 없거나 신뢰도가 부족한 탐지 · 접근 보류');
      }
      if (const {'parked_pm', 'pole', 'tree_trunk'}.contains(row['classId'])) {
        obstacles.add(parsed.obstacles[i]);
      }
    }
    return List.unmodifiable(obstacles);
  }
}
