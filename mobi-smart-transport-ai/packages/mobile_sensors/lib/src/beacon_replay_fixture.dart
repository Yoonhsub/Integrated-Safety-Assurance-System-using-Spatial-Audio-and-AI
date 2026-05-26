import 'dart:async';

import 'beacon_proximity_tracker.dart';
import 'beacon_scanner.dart';
import 'beacon_signal.dart';
import 'direction_sensor.dart';
import 'proximity_event_stream.dart';

/// 실제 BLE 기기 없이도 beacon signal 흐름을 재생하기 위한 한 frame이다.
///
/// JSON fixture에서 읽은 단일 시점의 [BeaconSignal]과 선택적인
/// [DirectionReading]을 함께 보관한다. [delay]는 UI나 통합 smoke test에서
/// 실제 시간 간격을 흉내 낼 때만 사용하며, 기본 테스트에서는 0으로 둔다.
class BeaconReplayFrame {
  const BeaconReplayFrame({
    required this.signal,
    this.direction,
    this.delay = Duration.zero,
    this.metadata = const {},
  });

  final BeaconSignal signal;
  final DirectionReading? direction;
  final Duration delay;
  final Map<String, Object?> metadata;

  Map<String, Object?> toJson() => {
        ...signal.toJson(),
        'direction': direction?.toJson(),
        'delayMs': delay.inMilliseconds,
        'metadata': metadata,
      };

  factory BeaconReplayFrame.fromJson(Map<String, Object?> json) {
    final delayMs = json['delayMs'];
    final direction = json['direction'];
    final metadata = json['metadata'];

    if (delayMs != null && delayMs is! num) {
      throw ArgumentError('BeaconReplayFrame.delayMs must be a number or null.');
    }
    if (direction != null && direction is! Map) {
      throw ArgumentError('BeaconReplayFrame.direction must be an object or null.');
    }
    if (metadata != null && metadata is! Map) {
      throw ArgumentError('BeaconReplayFrame.metadata must be an object or null.');
    }

    return BeaconReplayFrame(
      signal: BeaconSignal.fromJson(json),
      direction: direction == null
          ? null
          : DirectionReading.fromJson(Map<String, Object?>.from(direction as Map)),
      delay: Duration(milliseconds: (delayMs as num?)?.round() ?? 0),
      metadata: metadata == null
          ? const {}
          : Map<String, Object?>.from(metadata as Map),
    );
  }
}

/// mock/replay 검증에서 사용할 beacon signal sequence이다.
///
/// 섹션 6의 목적은 실제 BLE 없이도 `BEACON_NEAR`, `BEACON_LOST`,
/// `APPROACHING_STOP`, `LEAVING_STOP` 전환을 확인하는 것이다. 이 fixture는
/// 앱 UI를 직접 수정하지 않고 sensor package 내부에서 재현 가능한 입력 흐름만
/// 제공한다.
class BeaconReplayFixture {
  const BeaconReplayFixture({
    required this.name,
    required this.frames,
    this.description,
  }) : assert(name.length > 0, 'name must not be empty');

  final String name;
  final String? description;
  final List<BeaconReplayFrame> frames;

  Iterable<BeaconSignal> get signals => frames.map((frame) => frame.signal);

  MockBeaconScanner createScanner() => MockBeaconScanner(signals);

  /// [ProximityEventStreamAdapter.watch]에 넘길 수 있는 direction provider이다.
  ///
  /// 동일 beaconId와 timestamp를 가진 replay frame을 찾아 방향값을 반환한다.
  DirectionReading? directionForSignal(BeaconSignal signal) {
    for (final frame in frames) {
      if (frame.signal.beaconId == signal.beaconId &&
          frame.signal.lastDetectedAt.isAtSameMomentAs(signal.lastDetectedAt)) {
        return frame.direction;
      }
    }
    return null;
  }

  Map<String, Object?> toJson() => {
        'name': name,
        'description': description,
        'frames': frames.map((frame) => frame.toJson()).toList(),
      };

  factory BeaconReplayFixture.fromJson(Map<String, Object?> json) {
    final name = json['name'];
    final description = json['description'];
    final frames = json['frames'];

    if (name is! String || name.trim().isEmpty) {
      throw ArgumentError('BeaconReplayFixture.name must be a non-empty string.');
    }
    if (description != null && description is! String) {
      throw ArgumentError('BeaconReplayFixture.description must be a string or null.');
    }
    if (frames is! List) {
      throw ArgumentError('BeaconReplayFixture.frames must be a list.');
    }

    return BeaconReplayFixture(
      name: name.trim(),
      description: description as String?,
      frames: frames
          .map(
            (frame) => BeaconReplayFrame.fromJson(
              Map<String, Object?>.from(frame as Map),
            ),
          )
          .toList(growable: false),
    );
  }
}

/// replay fixture를 proximity event stream으로 변환하는 test/helper runner이다.
class ProximityEventReplayRunner {
  ProximityEventReplayRunner({
    required this.fixture,
    BeaconProximityTracker? tracker,
  }) : tracker = tracker ?? BeaconProximityTracker();

  final BeaconReplayFixture fixture;
  final BeaconProximityTracker tracker;

  Stream<ProximityEvent> events({String? targetBeaconId}) {
    final adapter = ProximityEventStreamAdapter(
      scanner: fixture.createScanner(),
      tracker: tracker,
    );
    return adapter.watch(
      targetBeaconId: targetBeaconId,
      directionProvider: fixture.directionForSignal,
    );
  }

  Future<List<ProximityEvent>> collectEvents({String? targetBeaconId}) {
    return events(targetBeaconId: targetBeaconId).toList();
  }
}
