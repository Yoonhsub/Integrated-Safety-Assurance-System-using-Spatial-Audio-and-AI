import 'package:flutter_test/flutter_test.dart';
import 'package:mobi_passenger_app/src/services/vision_scene_summary.dart';

Map<String, Object?> row(String id, double x, {double confidence = .9}) => {
      'classId': id,
      'className': VisionSceneSummaryTracker.classNames[id],
      'confidence': confidence,
      'bbox': {'x': x, 'y': .1, 'w': .1, 'h': .2},
    };
void main() {
  final epoch = DateTime.utc(2026);
  VisionSceneSummary frame(
      VisionSceneSummaryTracker tracker, int n, List<dynamic> rows,
      {int age = 0, String? id}) {
    final at = epoch.add(Duration(milliseconds: n * 100));
    return tracker.update(
        frameId: id ?? '$n',
        receivedAt: at,
        now: at.add(Duration(milliseconds: age)),
        detections: rows);
  }

  test('single requires distinct frames and carries receipt provenance', () {
    final tracker = VisionSceneSummaryTracker();
    final first = frame(tracker, 1, [row('pole', .1)]);
    expect(first.status, VisionSceneStatus.uncertain);
    expect(first.reason, 'confirming');
    expect(first.groups, isEmpty);
    final second = frame(tracker, 2, [row('pole', .1)]);
    expect(second.status, VisionSceneStatus.single);
    expect(second.receivedAt, epoch.add(const Duration(milliseconds: 200)));
    expect(second.briefText, '화면 왼쪽에 장애물이 감지됐습니다');
    expect(second.detailText, contains('보도 기둥 1개'));
  });
  test('multiple groups include every reliable object, not highest confidence',
      () {
    final tracker = VisionSceneSummaryTracker();
    final rows = [row('pole', .1, confidence: .5), row('tree_trunk', .45)];
    frame(tracker, 1, rows);
    final result = frame(tracker, 2, rows.reversed.toList());
    expect(result.status, VisionSceneStatus.multiple);
    expect(result.count, 2);
    expect(result.groups.map((g) => g.side),
        [VisionSceneSide.left, VisionSceneSide.center]);
    expect(result.briefText, '화면 왼쪽과 중앙에 장애물이 감지됐습니다');
    expect(result.detailText, contains('나무 줄기 1개'));
  });
  test('multiple same-side instances remain multiple and signature counts them',
      () {
    final tracker = VisionSceneSummaryTracker(confirmationFrames: 1);
    final single = frame(tracker, 1, [row('pole', .1)]);
    final multi = frame(tracker, 2, [row('pole', .1), row('pole', .2)]);
    expect(multi.status, VisionSceneStatus.multiple);
    expect(multi.groups.single.classCounts['pole'], 2);
    expect(multi.signature, isNot(single.signature));
    expect(multi.detailText, contains('보도 기둥 2개'));
  });
  test('class/side/count change immediately removes prior confident scene', () {
    final tracker = VisionSceneSummaryTracker();
    frame(tracker, 1, [row('bus', .1)]);
    frame(tracker, 2, [row('bus', .1)]);
    final changed = frame(tracker, 3, [row('bus', .8), row('pole', .1)]);
    expect(changed.status, VisionSceneStatus.uncertain);
    expect(changed.groups, isEmpty);
    expect(changed.briefText, '현재 화면을 확인하기 어렵습니다');
    expect(changed.detailText, isNot(contains('버스 1개')));
  });
  test('empty and below threshold are current uncertainty, not clear path', () {
    final tracker = VisionSceneSummaryTracker(confirmationFrames: 1);
    frame(tracker, 1, [row('pole', .1)]);
    for (var n = 2; n < 4; n++) {
      final result =
          frame(tracker, n, n == 2 ? [] : [row('pole', .1, confidence: .49)]);
      expect(result.reason, 'no_reliable_detections');
      expect(result.status, VisionSceneStatus.uncertain);
      expect(
          result.isFresh(epoch.add(Duration(milliseconds: n * 100))), isTrue);
      expect(result.detailText, contains('안전하다는 뜻은 아닙니다'));
      expect(result.groups, isEmpty);
    }
  });
  test(
      'mixed malformed rows invalidate scene instead of silently omitting them',
      () {
    final tracker = VisionSceneSummaryTracker(confirmationFrames: 1);
    final result = frame(tracker, 1, [
      row('pole', .1),
      {'classId': 'bus'}
    ]);
    expect(result.status, VisionSceneStatus.uncertain);
    expect(result.reason, 'invalid_detection');
    expect(result.groups, isEmpty);
  });
  test('invalid box confidence and label rejected', () {
    final tracker = VisionSceneSummaryTracker(confirmationFrames: 1);
    final invalid = [
      row('unknown', .1),
      row('bus', -.2),
      row('bus', .99),
      row('bus', .1, confidence: double.nan),
      row('bus', .1, confidence: 1.1),
      {...row('bus', .1), 'className': 'wrong'},
      {
        ...row('bus', .1),
        'bbox': {'x': .1, 'y': .1, 'w': 0, 'h': .1}
      }
    ];
    for (var i = 0; i < invalid.length; i++) {
      expect(frame(tracker, i + 1, [invalid[i]]).reason, 'invalid_detection');
    }
  });
  test('duplicate and out-of-order receipt cannot accumulate confirmation', () {
    final tracker = VisionSceneSummaryTracker();
    frame(tracker, 2, [row('pole', .1)]);
    expect(frame(tracker, 3, [row('pole', .1)], id: '2').status,
        VisionSceneStatus.unavailable);
    expect(frame(tracker, 1, [row('pole', .1)]).status,
        VisionSceneStatus.unavailable);
    expect(frame(tracker, 2, [row('pole', .1)], id: 'different').status,
        VisionSceneStatus.unavailable);
    expect(frame(tracker, 4, [row('pole', .1)]).status,
        VisionSceneStatus.uncertain);
  });
  test('future and stale frames unavailable at exact freshness bound', () {
    final tracker = VisionSceneSummaryTracker(confirmationFrames: 1);
    expect(frame(tracker, 1, [row('pole', .1)], age: -1).status,
        VisionSceneStatus.unavailable);
    final stale = frame(tracker, 2, [row('pole', .1)], age: 2000);
    expect(stale.status, VisionSceneStatus.unavailable);
    expect(stale.isFresh(epoch), isFalse);
    expect(frame(tracker, 3, [row('pole', .1)], age: 1999).status,
        VisionSceneStatus.single);
  });
  test('detail request uses same fresh snapshot, expiry hides all old labels',
      () {
    final tracker = VisionSceneSummaryTracker(confirmationFrames: 1);
    final initial = tracker.snapshot(epoch);
    expect(initial.reason, 'no_frame');
    expect(initial.isFresh(epoch), isFalse);
    final result = frame(tracker, 1, [row('bus', .8)]);
    expect(
        identical(
            tracker.snapshot(epoch.add(const Duration(milliseconds: 200))),
            result),
        isTrue);
    final stale =
        tracker.snapshot(epoch.add(const Duration(milliseconds: 2100)));
    expect(stale.status, VisionSceneStatus.unavailable);
    expect(stale.detailText, isNot(contains('버스')));
    expect(stale.groups, isEmpty);
  });
  test('large receipt gap resets temporal confirmation', () {
    final tracker = VisionSceneSummaryTracker();
    frame(tracker, 1, [row('pole', .1)]);
    expect(frame(tracker, 22, [row('pole', .1)]).status,
        VisionSceneStatus.uncertain);
  });
  test('groups and counts immutable, clear removes all session context', () {
    final tracker = VisionSceneSummaryTracker(confirmationFrames: 1);
    final result = frame(tracker, 1, [row('pole', .1)]);
    expect(() => result.groups.clear(), throwsUnsupportedError);
    expect(() => result.groups.single.classCounts['pole'] = 9,
        throwsUnsupportedError);
    tracker.clear();
    expect(tracker.snapshot(epoch).status, VisionSceneStatus.unavailable);
    expect(
        frame(tracker, 1, [row('pole', .1)]).status, VisionSceneStatus.single);
  });
  test(
      'mixed classes and all three sides are informational, no nearest selection',
      () {
    final tracker = VisionSceneSummaryTracker(confirmationFrames: 1);
    final result = frame(tracker, 1,
        [row('bus', .1), row('sidewalk', .45), row('obstacle', .8)]);
    expect(result.count, 3);
    expect(result.groups.length, 3);
    expect(result.briefText, '화면 왼쪽과 중앙과 오른쪽에 객체가 감지됐습니다');
    expect(result.detailText, contains('위험 여부'));
  });
  test('bounded input rejects whole scene rather than silently truncating', () {
    final tracker = VisionSceneSummaryTracker(confirmationFrames: 1);
    expect(frame(tracker, 1, List.generate(257, (_) => row('pole', .1))).status,
        VisionSceneStatus.unavailable);
  });
  test('invalidating a scene never forgets receipt order', () {
    final tracker = VisionSceneSummaryTracker(confirmationFrames: 1);
    frame(tracker, 10, [row('pole', .1)]);
    tracker.invalidate(reason: 'test_stop');
    expect(frame(tracker, 9, [row('bus', .8)]).reason, 'non_monotonic_receipt');
    tracker.invalidate(reason: 'another_error');
    expect(frame(tracker, 8, [row('bus', .8)]).status,
        VisionSceneStatus.unavailable);
    expect(
        frame(tracker, 11, [row('pole', .1)]).status, VisionSceneStatus.single);
  });
  test('side boundary fixtures and jitter never inherit prior confident side',
      () {
    Map<String, Object?> centered(double center) => {
          ...row('pole', .1),
          'bbox': {'x': center - .0625, 'y': .1, 'w': .125, 'h': .2}
        };
    final tracker = VisionSceneSummaryTracker(confirmationFrames: 1);
    final cases = <double, VisionSceneSide>{
      1 / 3 - .0001: VisionSceneSide.left,
      1 / 3: VisionSceneSide.center,
      2 / 3: VisionSceneSide.center,
      2 / 3 + .0001: VisionSceneSide.right
    };
    var n = 0;
    for (final item in cases.entries) {
      expect(frame(tracker, ++n, [centered(item.key)]).groups.single.side,
          item.value);
    }
    final stable = VisionSceneSummaryTracker(confirmationFrames: 2);
    for (var i = 1; i <= 8; i++) {
      final scene =
          frame(stable, i, [centered(1 / 3 + (i.isEven ? .0001 : -.0001))]);
      expect(scene.status, VisionSceneStatus.uncertain);
      expect(scene.groups, isEmpty);
    }
  });
  test('confidence threshold changes reset confirmation, not risk ranking', () {
    final tracker = VisionSceneSummaryTracker(confirmationFrames: 2);
    frame(tracker, 1, [row('pole', .1, confidence: .5)]);
    final low = frame(tracker, 2, [row('pole', .1, confidence: .499999)]);
    expect(low.reason, 'no_reliable_detections');
    expect(frame(tracker, 3, [row('pole', .1, confidence: .5)]).status,
        VisionSceneStatus.uncertain);
    expect(frame(tracker, 4, [row('pole', .1, confidence: .5)]).status,
        VisionSceneStatus.single);
  });
  test('receipt labels distinguish missing stale and clock reversal', () {
    expect(visionReceiptAgeLabel(null, epoch), '관찰 수신 기록 없음');
    expect(
        visionReceiptAgeLabel(
            epoch, epoch.subtract(const Duration(milliseconds: 1))),
        '수신 시계 확인 필요');
    expect(visionReceiptAgeLabel(epoch, epoch.add(const Duration(seconds: 2))),
        contains('오래된 관찰'));
    expect(
        visionReceiptAgeLabel(
            epoch, epoch.add(const Duration(milliseconds: 500))),
        contains('500 ms'));
    expect(visionSoftwarePhaseLabel('TTS_COMPLETED'), '음성 완료 콜백');
  });
}
