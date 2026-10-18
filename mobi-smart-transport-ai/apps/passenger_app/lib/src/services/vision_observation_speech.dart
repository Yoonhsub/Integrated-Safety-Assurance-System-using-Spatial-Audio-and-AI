import 'dart:async';
import 'dart:collection';
import 'package:flutter/foundation.dart';
import 'speech_priority_coordinator.dart';

class _Candidate {
  _Candidate(this.key, this.meaning, this.text, this.deadline);
  final String key, meaning, text;
  final int deadline;
}

/// Authenticated server observations only. No server mutation or safety input.
class VisionObservationSpeech extends ChangeNotifier {
  VisionObservationSpeech(this.priority,
      {int Function()? nowMicros,
      this.minimumInterval = const Duration(seconds: 8)})
      : _now = nowMicros ?? (() => _clock.elapsedMicroseconds) {
    priority.addListener(_priorityChanged);
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) => tick());
  }
  static final Stopwatch _clock = Stopwatch()..start();
  final SpeechPriorityCoordinator priority;
  final int Function() _now;
  final Duration minimumInterval;
  final Object _owner = Object();
  final LinkedHashMap<String, int> _deadlines = LinkedHashMap();
  final Set<String> _seen = {};
  final Map<String, (int, String)> _watermarks = {};
  Timer? _timer;
  String? _uid;
  String _session = '';
  Object? _scopeVersion;
  _Candidate? _current, _pending;
  String? _lastMeaning, _activeMeaning;
  int _epoch = 0;
  int? _lastStarted;
  bool enabled = false, speaking = false, _busy = false, _disposed = false;
  String? error;
  String get status =>
      error ??
      (!enabled
          ? 'Vision 음성 OFF'
          : priority.priorityActive
              ? '기존 안내 우선 · Vision 음성 보류'
              : speaking
                  ? 'Vision 관찰 음성 준비·안내 중'
                  : 'Vision 음성 ON · 관찰 대기');

  void _remember(String key) {
    _seen.add(key);
    if (_seen.length > 128) _seen.remove(_seen.first);
  }

  void setScope(String? uid, String session, Object? version) {
    if (_uid == uid && _session == session && _scopeVersion == version) return;
    _uid = uid;
    _session = session;
    _scopeVersion = version;
    enabled = false;
    error = null;
    _watermarks.clear();
    _deadlines.clear();
    _seen.clear();
    _lastMeaning = null;
    _lastStarted = null;
    _current = null;
    _cancel();
  }

  void setEnabled(bool value) {
    enabled = value;
    error = null;
    if (!value) {
      _lastMeaning = _current?.meaning;
      _cancel();
    } else {
      _lastMeaning = null;
      _seen.clear();
      _consider();
    }
    _notify();
  }

  void stop() {
    _lastMeaning = _current?.meaning;
    if (_current != null) _remember(_current!.key);
    _cancel();
  }

  void clear() {
    _current = null;
    _lastMeaning = null;
    _cancel();
  }

  void update(List<Map<String, dynamic>> items, Duration requestLatency) {
    _Candidate? selected;
    final candidates = <(String, String, String, bool, bool, int)>[];
    var onlyStale = false;
    for (final item in items) {
      final ttl = item['validForSeconds'];
      final classes = item['observedClasses'];
      final source = item['sourceType'];
      final fields = ['sessionId', 'cameraId', 'cameraEpoch', 'visionEventId'];
      final index = item['frameIndex'];
      if (index is! int ||
          index < 0 ||
          fields
              .any((f) => item[f] is! String || (item[f] as String).isEmpty) ||
          item['sessionId'] != _session) {
        continue;
      }
      final camera =
          jsonKey([item['cameraId'] as String, item['cameraEpoch'] as String]);
      final mark = _watermarks[camera];
      final event = item['visionEventId'] as String;
      if (mark != null &&
          (index < mark.$1 || (index == mark.$1 && event != mark.$2))) {
        onlyStale = true;
        continue;
      }
      _watermarks[camera] = (index, event);
      if (_watermarks.length > 64) _watermarks.remove(_watermarks.keys.first);

      if (_uid == null ||
          _uid!.isEmpty ||
          _session.isEmpty ||
          item['sessionId'] != _session ||
          item['state'] != 'available' ||
          item['inferenceStatus'] != 'ok' ||
          (source != 'replay' && source != 'live') ||
          ttl is! num ||
          !ttl.isFinite ||
          classes is! List ||
          fields
              .any((f) => item[f] is! String || (item[f] as String).isEmpty)) {
        continue;
      }
      final bus = classes.contains('bus'), door = classes.contains('bus_door');
      if (!bus && !door) continue;
      final key = jsonKey([_uid!, ...fields.map((f) => item[f] as String)]);
      final proposed =
          _now() + (ttl * 1000000).floor() - requestLatency.inMicroseconds;
      final previous = _deadlines[key];
      final deadline =
          previous == null || proposed < previous ? proposed : previous;
      _deadlines[key] =
          deadline; // Same receipt cannot renew its monotonic TTL.
      if (_deadlines.length > 128) {
        final oldest = _deadlines.keys.first;
        _deadlines.remove(oldest);
        _seen.remove(oldest);
      }
      if (deadline <= _now()) continue;
      candidates.add((key, camera, source as String, bus, door, deadline));
    }
    if (candidates.isNotEmpty) {
      candidates.sort((a, b) => a.$1.compareTo(b.$1));
      final parts = <String>[];
      final meanings = <String>[];
      for (final source in ['live', 'replay']) {
        final group = candidates.where((c) => c.$3 == source).toList();
        if (group.isEmpty) continue;
        final bus = group.any((c) => c.$4), door = group.any((c) => c.$5);
        final target = bus && door
            ? '버스와 버스 문이'
            : door
                ? '버스 문이'
                : '버스가';
        final cameras = group.map((c) => c.$2).toSet().length;
        final prefix = cameras > 1
            ? (source == 'replay' ? '여러 카메라의 녹화 영상 관찰에서 ' : '여러 카메라의 관찰에서 ')
            : (source == 'replay' ? '녹화 영상에서 ' : '');
        parts.add('$prefix$target 감지되었습니다.');
        meanings.add('$source:$bus:$door:${cameras > 1}');
      }
      selected = _Candidate(
          jsonKey(candidates.map((c) => c.$1).toList()),
          meanings.join('|'),
          parts.join(' '),
          candidates.map((c) => c.$6).reduce((a, b) => a < b ? a : b));
    }
    // A stale-only response cannot replace still-valid newer evidence.
    if (selected == null &&
        onlyStale &&
        _current != null &&
        _current!.deadline > _now()) {
      _consider();
      return;
    }
    _current = selected;
    if (priority.priorityActive && selected != null) {
      _remember(selected.key);
      _lastMeaning = selected.meaning;
      _pending = null;
    }
    if (selected == null) {
      _lastMeaning = null;
      _cancel();
    } else if (_activeMeaning != null && _activeMeaning != selected.meaning) {
      _cancel();
    }
    _consider();
  }

  static String jsonKey(List<String> fields) =>
      fields.map((v) => '${v.length}:$v').join();
  bool _valid(_Candidate item, int epoch) =>
      !_disposed &&
      enabled &&
      epoch == _epoch &&
      !priority.priorityActive &&
      _uid != null &&
      _current?.meaning == item.meaning &&
      _current!.deadline > _now();
  void _consider() {
    final item = _current;
    if (_disposed ||
        !enabled ||
        item == null ||
        item.deadline <= _now() ||
        priority.priorityActive ||
        item.meaning == _lastMeaning ||
        _seen.contains(item.key)) {
      return;
    }
    _pending = item;
    if (!_busy &&
        (_lastStarted == null ||
            _now() - _lastStarted! >= minimumInterval.inMicroseconds)) {
      unawaited(_speak(item));
    }
  }

  Future<void> _speak(_Candidate item) async {
    _busy = true;
    _pending = null;
    final epoch = _epoch;
    _remember(item.key);
    _lastMeaning = item.meaning;
    _lastStarted = _now();
    _activeMeaning = item.meaning;
    speaking = true;
    _notify();
    try {
      await priority.speakObservation(
          _owner, item.text, () => _valid(item, epoch));
    } catch (_) {
      if (!_disposed && epoch == _epoch) {
        error = 'Vision 음성을 사용할 수 없습니다. 한국어 음성·브라우저 설정을 확인하고 다시 켜주세요.';
        enabled = false;
        _pending = null;
      }
    } finally {
      _busy = false;
      if (!_disposed && epoch == _epoch) {
        speaking = false;
        _activeMeaning = null;
        _notify();
      }
      if (!_disposed) _consider();
    }
  }

  void tick() {
    if (_current != null && _current!.deadline <= _now()) clear();
    if (_pending != null) _consider();
  }

  void _priorityChanged() {
    if (priority.priorityActive) {
      if (_current != null) {
        _remember(_current!.key);
        _lastMeaning = _current!.meaning;
      }
      _pending = null;
      _cancel();
    }
    _notify();
  }

  void _cancel() {
    _epoch++;
    _pending = null;
    _activeMeaning = null;
    speaking = false;
    unawaited(priority.stopObservation(_owner).catchError((Object _) {}));
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    _current = null;
    _pending = null;
    _timer?.cancel();
    priority.removeListener(_priorityChanged);
    unawaited(priority.stopObservation(_owner).catchError((Object _) {}));
    super.dispose();
  }
}
