import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_passenger_app/src/services/vision_ping_tracker.dart';

Map<String, Object?> row(String id, {double x = .1, double confidence = .8}) =>
    {
      'classId': id,
      'className': VisionPingTracker.classNames[id],
      'confidence': confidence,
      'bbox': {'x': x, 'y': .1, 'w': .2, 'h': .2}
    };
void main() {
  final epoch = DateTime.utc(2026);
  VisionPingSnapshot frame(VisionPingTracker t, int n, List<dynamic> rows,
      {int age = 0, String? id}) {
    final at = epoch.add(Duration(milliseconds: n * 100));
    return t.update(
        frameId: id ?? '$n',
        capturedAt: at,
        now: at.add(Duration(milliseconds: age)),
        detections: rows);
  }

  test('distinct fresh matching frames confirm, proximity always unknown', () {
    final t = VisionPingTracker();
    final a = frame(t, 1, [row('pole')]);
    expect(a.selected, isNull);
    final b = frame(t, 2, [row('pole', x: .11)]);
    expect(b.selected!.id, a.tracks.single.id);
    expect(b.selected!.consecutiveFrames, 2);
    expect(b.selected!.proximity, 'UNKNOWN');
    expect(b.proximity, 'UNKNOWN');
  });
  test('one-to-one multiobject IDs stable after row reorder', () {
    final t = VisionPingTracker(confirmationFrames: 1);
    final a = frame(t, 1, [row('pole'), row('pole', x: .65)]);
    final b = frame(t, 2, [row('pole', x: .66), row('pole', x: .11)]);
    for (final old in a.tracks) {
      expect(
          b.tracks.firstWhere((v) => (v.bbox.x < .5) == (old.bbox.x < .5)).id,
          old.id);
    }
    expect(b.tracks.map((v) => v.id).toSet().length, 2);
    expect(b.selected!.id, a.selected!.id);
  });
  test('class change and nonoverlap require new confirmation', () {
    final t = VisionPingTracker();
    final a = frame(t, 1, [row('pole')]);
    final b = frame(t, 2, [row('tree_trunk')]);
    expect(b.tracks.single.id, isNot(a.tracks.single.id));
    expect(b.selected, isNull);
    final c = frame(t, 3, [row('tree_trunk', x: .7)]);
    expect(c.tracks.single.id, isNot(b.tracks.single.id));
    expect(c.selected, isNull);
  });
  test('omission clears and returning object gets new ID', () {
    final t = VisionPingTracker();
    frame(t, 1, [row('bus')]);
    final a = frame(t, 2, [row('bus')]);
    final empty = frame(t, 3, []);
    expect(empty.tracks, isEmpty);
    expect(empty.selected, isNull);
    final b = frame(t, 4, [row('bus')]);
    expect(b.selected, isNull);
    expect(b.tracks.single.id, isNot(a.selected!.id));
  });
  test('class tier not confidence determines informational selection', () {
    final t = VisionPingTracker(confirmationFrames: 1);
    final a = frame(t, 1, [
      row('bus_stop', confidence: .99),
      row('bus', confidence: .95),
      row('pole', confidence: .5)
    ]);
    expect(a.selected!.classId, 'pole');
    expect(a.selected!.priorityTier, 0);
    expect(a.selected!.infoKind, 'CAMERA_IMAGE_INFORMATION');
    expect(VisionPingTracker.informationalPriority('bus_door'), 1);
    expect(VisionPingTracker.informationalPriority('bus_stop'), 2);
    expect(VisionPingTracker.informationalPriority('sidewalk'), 3);
  });
  test('retain confirmed selection until higher tier confirmed', () {
    final t = VisionPingTracker();
    frame(t, 1, [row('bus')]);
    final a = frame(t, 2, [row('bus')]);
    expect(frame(t, 3, [row('bus'), row('pole')]).selected!.id, a.selected!.id);
    expect(frame(t, 4, [row('bus'), row('pole')]).selected!.classId, 'pole');
  });
  test('repeated ID clears and does not increase confirmation', () {
    final t = VisionPingTracker();
    frame(t, 1, [row('bus')]);
    final repeat = frame(t, 2, [row('bus')], id: '1');
    expect(repeat.accepted, isFalse);
    expect(repeat.selected, isNull);
    expect(frame(t, 3, [row('bus')]).selected, isNull);
  });
  test('older and equal timestamps fail closed', () {
    final t = VisionPingTracker(confirmationFrames: 1);
    frame(t, 3, [row('bus')]);
    expect(frame(t, 2, [row('bus')]).accepted, isFalse);
    expect(frame(t, 3, [row('bus')], id: 'other').accepted, isFalse);
  });
  test('stale and future frames rejected, long fresh-frame gap resets streak',
      () {
    final t = VisionPingTracker();
    expect(frame(t, 1, [row('bus')], age: 2000).accepted, isFalse);
    expect(frame(t, 2, [row('bus')], age: -1).accepted, isFalse);
    expect(frame(t, 3, [row('bus')], age: 1999).accepted, isTrue);
    expect(frame(t, 24, [row('bus')]).selected, isNull);
  });
  test('malformed rows cannot retain selection', () {
    final t = VisionPingTracker(confirmationFrames: 1);
    frame(t, 1, [row('bus')]);
    final a = frame(t, 2, [
      null,
      {},
      row('unknown'),
      row('bus', x: -.1),
      row('bus', x: .9),
      row('bus', confidence: double.infinity),
      row('bus', confidence: .49),
      {...row('bus'), 'className': 'wrong'},
      {
        ...row('bus'),
        'bbox': {'x': .1, 'y': .1, 'w': double.nan, 'h': .1}
      }
    ]);
    expect(a.tracks, isEmpty);
    expect(a.selected, isNull);
  });
  test('bounded storage and excessive input rejection', () {
    final t = VisionPingTracker(confirmationFrames: 1, maxTracks: 2);
    final a = frame(t, 1, [row('bus_stop'), row('bus'), row('pole')]);
    expect(a.tracks.length, 2);
    expect(a.selected!.classId, 'pole');
    final b = frame(t, 2, List.generate(257, (_) => row('bus')));
    expect(b.accepted, isFalse);
    expect(b.tracks, isEmpty);
  });
  test('immutable snapshot and nested row do not alias input', () {
    final t = VisionPingTracker(confirmationFrames: 1);
    final r = row('bus');
    final a = frame(t, 1, [r]);
    (r['bbox'] as Map)['x'] = .7;
    expect(a.selected!.bbox.x, .1);
    expect(() => a.tracks.clear(), throwsUnsupportedError);
    final out = a.selected!.toDetection();
    expect(() => out['confidence'] = 0, throwsUnsupportedError);
    expect(() => (out['bbox'] as Map)['x'] = 0.0, throwsUnsupportedError);
  });
  test('clear restarts session without recycling track ID', () {
    final t = VisionPingTracker(confirmationFrames: 1);
    final a = frame(t, 1, [row('bus')]);
    t.clear();
    final b = frame(t, 1, [row('bus')]);
    expect(b.accepted, isTrue);
    expect(b.selected!.id, isNot(a.selected!.id));
  });
  test('reject invalid config', () {
    expect(() => VisionPingTracker(confirmationFrames: 0), throwsArgumentError);
    expect(() => VisionPingTracker(maxTracks: 0), throwsArgumentError);
    expect(() => VisionPingTracker(minIou: double.nan), throwsArgumentError);
    expect(() => VisionPingTracker(maxFrameAge: Duration.zero),
        throwsArgumentError);
  });
}
