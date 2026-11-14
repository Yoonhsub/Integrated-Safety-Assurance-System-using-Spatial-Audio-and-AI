/// Camera-screen information only. This does not estimate physical danger,
/// distance, travel direction, object identity, or whether a path is clear.
enum VisionSceneStatus { single, multiple, uncertain, unavailable }

enum VisionSceneSide { left, center, right }

class VisionSceneGroup {
  VisionSceneGroup(this.side, Map<String, int> classCounts)
      : classCounts = Map.unmodifiable(classCounts);
  final VisionSceneSide side;
  final Map<String, int> classCounts;
  int get count => classCounts.values.fold(0, (a, b) => a + b);
  String get sideLabel => switch (side) {
        VisionSceneSide.left => '왼쪽',
        VisionSceneSide.center => '중앙',
        VisionSceneSide.right => '오른쪽',
      };
}

class VisionSceneSummary {
  VisionSceneSummary._(
      {required this.status,
      required this.reason,
      required List<VisionSceneGroup> groups,
      required this.receivedAt,
      required this.maxAge})
      : groups = List.unmodifiable(groups);
  final VisionSceneStatus status;
  final String reason;
  String get statusLabel => switch (status) {
        VisionSceneStatus.single => '단일',
        VisionSceneStatus.multiple => '다중',
        VisionSceneStatus.uncertain => '불확실',
        VisionSceneStatus.unavailable => '사용 불가',
      };
  final List<VisionSceneGroup> groups;

  /// Host receipt time, NOT sensor capture time or acquisition-order evidence.
  final DateTime? receivedAt;
  final Duration maxAge;
  int get count => groups.fold(0, (n, group) => n + group.count);
  bool get reliable =>
      status == VisionSceneStatus.single ||
      status == VisionSceneStatus.multiple;
  String get signature =>
      '${status.name}:$reason:${groups.map((g) => '${g.side.name}:${g.classCounts.entries.map((e) => '${e.key}:${e.value}').join(',')}').join('|')}';
  bool isFresh(DateTime now) {
    if (status == VisionSceneStatus.unavailable) return false;
    final received = receivedAt;
    if (received == null) return false;
    final age = now.difference(received);
    return !age.isNegative && age < maxAge;
  }

  String get briefText {
    if (!reliable) return '현재 화면을 확인하기 어렵습니다';
    final locations = groups.map((group) => group.sideLabel).join('과 ');
    final classes = groups.expand((group) => group.classCounts.keys).toSet();
    final noun =
        classes.every(VisionSceneSummaryTracker.obstacleClasses.contains)
            ? '장애물'
            : classes.length == 1
                ? VisionSceneSummaryTracker.classNames[classes.single]!
                : '객체';
    return '화면 $locations에 $noun${noun == '객체' ? '가' : _subjectParticle(noun)} 감지됐습니다';
  }

  static String _subjectParticle(String text) {
    final last = text.runes.last;
    return last >= 0xAC00 && last <= 0xD7A3 && (last - 0xAC00) % 28 != 0
        ? '이'
        : '가';
  }

  String get detailText {
    if (!reliable) {
      return reason == 'no_reliable_detections'
          ? '현재 화면에서 신뢰할 수 있는 검출이 없습니다. 장애물이 없거나 길이 안전하다는 뜻은 아닙니다.'
          : '현재 화면을 확인하기 어렵습니다. 새로운 화면을 받은 뒤 다시 확인해 주세요.';
    }
    final parts = groups.map((group) {
      final labels = group.classCounts.entries
          .map((entry) =>
              '${VisionSceneSummaryTracker.classNames[entry.key]} ${entry.value}개')
          .join(', ');
      return '${group.sideLabel}에 $labels';
    }).join('. ');
    return '화면 $parts. 실제 거리와 위험 여부, 이동 방향은 알 수 없습니다.';
  }
}

class VisionSceneSummaryTracker {
  VisionSceneSummaryTracker(
      {this.confirmationFrames = 2, this.maxAge = const Duration(seconds: 2)}) {
    if (confirmationFrames < 1 || maxAge <= Duration.zero) {
      throw ArgumentError(
          'Positive confirmation and freshness limits required');
    }
  }
  final int confirmationFrames;
  final Duration maxAge;
  static const obstacleClasses = {
    'pole',
    'tree_trunk',
    'parked_pm',
    'obstacle'
  };
  static const classNames = {
    'bus': '버스',
    'bus_door': '버스 문',
    'bus_stop': '버스 정류장',
    'parked_pm': '방치 전동 킥보드',
    'pole': '보도 기둥',
    'tree_trunk': '나무 줄기',
    'obstacle': '장애물',
    'roadway': '차도',
    'sidewalk': '보도',
    'tactile_paving': '점자블록',
  };
  final Set<String> _seen = {};
  DateTime? _lastReceived;
  String? _signature;
  int _streak = 0;
  VisionSceneSummary? _latest;

  void clear() {
    _seen.clear();
    _lastReceived = null;
    _signature = null;
    _streak = 0;
    _latest = null;
  }

  /// Retire a result without forgetting frame order. A delayed older frame must
  /// not become current merely because an invalid/stale result interrupted it.
  void invalidate({String reason = 'invalidated'}) {
    _unreliable(VisionSceneStatus.unavailable, reason);
  }

  VisionSceneSummary _unreliable(VisionSceneStatus status, String reason,
      {DateTime? receivedAt, bool reset = true}) {
    if (reset) {
      _signature = null;
      _streak = 0;
    }
    return _latest = VisionSceneSummary._(
        status: status,
        reason: reason,
        groups: const [],
        receivedAt: receivedAt,
        maxAge: maxAge);
  }

  /// Call at the time of an explicit detail request, never reuse stale text.
  VisionSceneSummary snapshot(DateTime now) {
    final latest = _latest;
    if (latest == null) {
      return _unreliable(VisionSceneStatus.unavailable, 'no_frame');
    }
    if (latest.status == VisionSceneStatus.unavailable) return latest;
    if (!latest.isFresh(now)) {
      return _unreliable(
          VisionSceneStatus.unavailable, 'stale_or_future_frame');
    }
    return latest;
  }

  VisionSceneSummary update(
      {required String frameId,
      required DateTime receivedAt,
      required DateTime now,
      required List<dynamic> detections}) {
    if (frameId.isEmpty || _seen.contains(frameId)) {
      return _unreliable(
          VisionSceneStatus.unavailable, 'repeated_or_invalid_frame');
    }
    _seen.add(frameId);
    if (_seen.length > 256) _seen.remove(_seen.first);
    if (_lastReceived != null && !receivedAt.isAfter(_lastReceived!)) {
      return _unreliable(
          VisionSceneStatus.unavailable, 'non_monotonic_receipt');
    }
    final age = now.difference(receivedAt);
    if (age.isNegative || age >= maxAge) {
      return _unreliable(
          VisionSceneStatus.unavailable, 'stale_or_future_frame');
    }
    if (_lastReceived != null &&
        receivedAt.difference(_lastReceived!) >= maxAge) {
      _signature = null;
      _streak = 0;
    }
    _lastReceived = receivedAt;
    if (detections.length > 256) {
      return _unreliable(VisionSceneStatus.unavailable, 'invalid_frame',
          receivedAt: receivedAt);
    }
    final counts = <VisionSceneSide, Map<String, int>>{};
    var invalid = false;
    for (final row in detections) {
      if (row is! Map ||
          !classNames.containsKey(row['classId']) ||
          row['className'] != classNames[row['classId']]) {
        invalid = true;
        continue;
      }
      final c = row['confidence'], box = row['bbox'];
      if (c is! num ||
          !c.isFinite ||
          c < 0 ||
          c > 1 ||
          box is! Map ||
          ['x', 'y', 'w', 'h']
              .any((k) => box[k] is! num || !(box[k] as num).isFinite)) {
        invalid = true;
        continue;
      }
      final x = (box['x'] as num).toDouble(), y = (box['y'] as num).toDouble();
      final w = (box['w'] as num).toDouble(), h = (box['h'] as num).toDouble();
      if (x < 0 ||
          y < 0 ||
          w <= 0 ||
          h <= 0 ||
          x + w > 1.000000001 ||
          y + h > 1.000000001) {
        invalid = true;
        continue;
      }
      // Confidence is a reliability threshold only, never a risk/priority score.
      if (c < .5) continue;
      final center = x + w / 2;
      final side = center < 1 / 3
          ? VisionSceneSide.left
          : center > 2 / 3
              ? VisionSceneSide.right
              : VisionSceneSide.center;
      final group = counts.putIfAbsent(side, () => {});
      final id = row['classId'] as String;
      group[id] = (group[id] ?? 0) + 1;
    }
    if (invalid) {
      return _unreliable(VisionSceneStatus.uncertain, 'invalid_detection',
          receivedAt: receivedAt);
    }
    if (counts.isEmpty) {
      return _unreliable(VisionSceneStatus.uncertain, 'no_reliable_detections',
          receivedAt: receivedAt);
    }
    final groups = <VisionSceneGroup>[];
    for (final side in VisionSceneSide.values) {
      final entries = counts[side];
      if (entries == null) continue;
      final keys = entries.keys.toList()..sort();
      groups.add(
          VisionSceneGroup(side, {for (final key in keys) key: entries[key]!}));
    }
    final signature = groups
        .map((g) =>
            '${g.side.name}:${g.classCounts.entries.map((e) => '${e.key}:${e.value}').join(',')}')
        .join('|');
    if (signature == _signature) {
      _streak++;
    } else {
      _signature = signature;
      _streak = 1;
    }
    if (_streak < confirmationFrames) {
      return _unreliable(VisionSceneStatus.uncertain, 'confirming',
          receivedAt: receivedAt, reset: false);
    }
    final count = groups.fold<int>(0, (n, group) => n + group.count);
    return _latest = VisionSceneSummary._(
        status:
            count == 1 ? VisionSceneStatus.single : VisionSceneStatus.multiple,
        reason: 'confirmed',
        groups: groups,
        receivedAt: receivedAt,
        maxAge: maxAge);
  }
}

/// Wall-clock receipt age is a freshness display, not acoustic latency.
String visionReceiptAgeLabel(DateTime? receipt, DateTime now) {
  if (receipt == null) return '관찰 수신 기록 없음';
  final age = now.difference(receipt);
  if (age.isNegative) return '수신 시계 확인 필요';
  if (age >= const Duration(seconds: 2)) return '오래된 관찰 · 새 화면 대기';
  return '수신 기준 ${age.inMilliseconds} ms 경과';
}

String visionSoftwarePhaseLabel(String? phase) => switch (phase) {
      'REQUESTED' => '출력 요청',
      'CUE_START' => '핑 시작 요청',
      'CUE_COMPLETED' => '핑 완료 콜백',
      'CUE_STOP_CONFIRMED' => '핑 정지 확인',
      'TTS_START' => '음성 시작 요청',
      'TTS_COMPLETED' => '음성 완료 콜백',
      'STOP_REQUESTED' => '출력 정지 요청',
      'CANCELLED' => '출력 취소',
      'FAILED' => '출력 오류',
      _ => '출력 기록 없음',
    };
