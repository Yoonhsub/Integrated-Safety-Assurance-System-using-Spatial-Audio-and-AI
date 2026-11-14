/// Informational image-space continuity only. IDs are not physical identity.
/// Neither confidence nor box size implies risk, range or travel direction.
class VisionPingBox {
  const VisionPingBox(this.x, this.y, this.w, this.h);
  final double x, y, w, h;
  double get centerX => x + w / 2;
  Map<String, double> toMap() =>
      Map.unmodifiable({'x': x, 'y': y, 'w': w, 'h': h});

  double iou(VisionPingBox other) {
    final left = x > other.x ? x : other.x;
    final top = y > other.y ? y : other.y;
    final right = x + w < other.x + other.w ? x + w : other.x + other.w;
    final bottom = y + h < other.y + other.h ? y + h : other.y + other.h;
    if (right <= left || bottom <= top) return 0;
    final intersection = (right - left) * (bottom - top);
    return intersection / (w * h + other.w * other.h - intersection);
  }
}

class VisionPingTrack {
  const VisionPingTrack(
      {required this.id,
      required this.classId,
      required this.className,
      required this.bbox,
      required this.confidence,
      required this.consecutiveFrames,
      required this.confirmed});
  final int id, consecutiveFrames;
  final String classId, className;
  final VisionPingBox bbox;
  final double confidence;
  final bool confirmed;
  String get proximity => 'UNKNOWN';
  int get priorityTier => VisionPingTracker.informationalPriority(classId);
  String get infoKind => 'CAMERA_IMAGE_INFORMATION';
  Map<String, Object?> toDetection() => Map.unmodifiable({
        'classId': classId,
        'className': className,
        'confidence': confidence,
        'bbox': bbox.toMap(),
      });
}

class VisionPingSnapshot {
  VisionPingSnapshot(
      {required this.accepted,
      required this.reason,
      required List<VisionPingTrack> tracks,
      this.selected})
      : tracks = List.unmodifiable(tracks);
  final bool accepted;
  final String reason;
  final List<VisionPingTrack> tracks;
  final VisionPingTrack? selected;
  String get proximity => 'UNKNOWN';
}

class VisionPingTracker {
  VisionPingTracker(
      {this.confirmationFrames = 2,
      this.maxTracks = 16,
      this.maxFrameAge = const Duration(seconds: 2),
      this.minIou = .3}) {
    if (confirmationFrames < 1 ||
        maxTracks < 1 ||
        maxTracks > 256 ||
        maxFrameAge <= Duration.zero ||
        !minIou.isFinite ||
        minIou <= 0 ||
        minIou > 1) {
      throw ArgumentError('Invalid informational tracker configuration');
    }
  }
  final int confirmationFrames, maxTracks;
  final Duration maxFrameAge;
  final double minIou;
  List<VisionPingTrack> _tracks = [];
  int _nextId = 1;
  int? _selectedId;
  final Set<String> _seenFrames = <String>{};
  DateTime? _lastCapturedAt;

  // Display labels match the existing camera detection contract.
  static const classNames = {
    'bus': '버스',
    'bus_door': '버스 문',
    'bus_stop': '버스 정류장',
    'parked_pm': '방치 전동 킥보드',
    'pole': '보도 기둥',
    'tree_trunk': '나무 줄기',
    'roadway': '차도',
    'sidewalk': '보도',
    'obstacle': '장애물',
    'tactile_paving': '점자블록',
  };

  /// Lower values are informational presentation tiers, NOT risk levels.
  static int informationalPriority(String classId) => switch (classId) {
        'pole' || 'tree_trunk' || 'parked_pm' || 'obstacle' => 0,
        'bus_door' || 'bus' => 1,
        'bus_stop' => 2,
        _ => 3,
      };

  /// Call clear on session changes. Capture timestamps must be monotonic per session.
  /// Host callback timestamps cannot establish sensor-level acquisition order.
  void clear() {
    _tracks = [];
    _selectedId = null;
    _seenFrames.clear();
    _lastCapturedAt = null;
    // Never recycle IDs within this tracker instance, including across resets.
  }

  VisionPingSnapshot _reject(String reason) {
    _tracks = [];
    _selectedId = null;
    return VisionPingSnapshot(
        accepted: false, reason: reason, tracks: const []);
  }

  VisionPingSnapshot update(
      {required String frameId,
      required DateTime capturedAt,
      required DateTime now,
      required List<dynamic> detections}) {
    if (frameId.isEmpty || _seenFrames.contains(frameId)) {
      return _reject('repeated_or_invalid_frame');
    }
    _seenFrames.add(frameId);
    if (_seenFrames.length > 256) _seenFrames.remove(_seenFrames.first);
    if (_lastCapturedAt != null && !capturedAt.isAfter(_lastCapturedAt!)) {
      return _reject('non_monotonic_timestamp');
    }
    final age = now.difference(capturedAt);
    if (age.isNegative || age >= maxFrameAge) return _reject('stale_frame');
    // A long input gap must not accumulate confirmation across stale observations.
    if (_lastCapturedAt != null &&
        capturedAt.difference(_lastCapturedAt!) >= maxFrameAge) {
      _tracks = [];
      _selectedId = null;
    }
    _lastCapturedAt = capturedAt;
    if (detections.length > 256) return _reject('too_many_detections');
    final rows = <VisionPingTrack>[];
    for (final row in detections) {
      if (row is! Map ||
          !classNames.containsKey(row['classId']) ||
          row['className'] != classNames[row['classId']]) {
        continue;
      }
      final b = row['bbox'], c = row['confidence'];
      if (b is! Map ||
          c is! num ||
          !c.isFinite ||
          c < .5 ||
          c > 1 ||
          ['x', 'y', 'w', 'h']
              .any((k) => b[k] is! num || !(b[k] as num).isFinite)) {
        continue;
      }
      final x = (b['x'] as num).toDouble(), y = (b['y'] as num).toDouble();
      final w = (b['w'] as num).toDouble(), h = (b['h'] as num).toDouble();
      if (x < 0 ||
          y < 0 ||
          w <= 0 ||
          h <= 0 ||
          x + w > 1.000000001 ||
          y + h > 1.000000001) {
        continue;
      }
      rows.add(VisionPingTrack(
          id: 0,
          classId: row['classId'] as String,
          className: row['className'] as String,
          bbox: VisionPingBox(x, y, w, h),
          confidence: c.toDouble(),
          consecutiveFrames: 1,
          confirmed: false));
    }
    // Global greedy one-to-one same-class IoU association, never confidence rank.
    final pairs = <({int oldIndex, int newIndex, double overlap})>[];
    for (var a = 0; a < _tracks.length; a++) {
      for (var b = 0; b < rows.length; b++) {
        if (_tracks[a].classId != rows[b].classId) continue;
        final overlap = _tracks[a].bbox.iou(rows[b].bbox);
        if (overlap >= minIou) {
          pairs.add((oldIndex: a, newIndex: b, overlap: overlap));
        }
      }
    }
    pairs.sort((a, b) {
      final overlap = b.overlap.compareTo(a.overlap);
      if (overlap != 0) return overlap;
      final old = _tracks[a.oldIndex].id.compareTo(_tracks[b.oldIndex].id);
      return old != 0 ? old : a.newIndex.compareTo(b.newIndex);
    });
    final usedOld = <int>{}, matches = <int, VisionPingTrack>{};
    for (final pair in pairs) {
      if (usedOld.contains(pair.oldIndex) ||
          matches.containsKey(pair.newIndex)) {
        continue;
      }
      usedOld.add(pair.oldIndex);
      matches[pair.newIndex] = _tracks[pair.oldIndex];
    }
    final next = <VisionPingTrack>[];
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i], previous = matches[i];
      final count = (previous?.consecutiveFrames ?? 0) + 1;
      next.add(VisionPingTrack(
          id: previous?.id ?? _nextId++,
          classId: row.classId,
          className: row.className,
          bbox: row.bbox,
          confidence: row.confidence,
          consecutiveFrames: count,
          confirmed: count >= confirmationFrames));
    }
    next.sort((a, b) {
      final priority = informationalPriority(a.classId)
          .compareTo(informationalPriority(b.classId));
      if (priority != 0) return priority;
      if (a.id == b.id) return 0;
      if (a.id == _selectedId) return -1;
      if (b.id == _selectedId) return 1;
      return a.id.compareTo(b.id);
    });
    _tracks = next.take(maxTracks).toList();
    final confirmed = _tracks.where((track) => track.confirmed);
    final selected = confirmed.isEmpty ? null : confirmed.first;
    _selectedId = selected?.id;
    return VisionPingSnapshot(
        accepted: true,
        reason: rows.isEmpty ? 'no_valid_detections' : 'ok',
        tracks: _tracks,
        selected: selected);
  }
}
