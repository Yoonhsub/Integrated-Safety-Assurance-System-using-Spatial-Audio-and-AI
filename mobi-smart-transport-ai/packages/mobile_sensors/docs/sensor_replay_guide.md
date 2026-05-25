# Sensor Replay Guide — 안준환 V2 섹션 11

이 문서는 Passenger App 담당자가 실제 BLE 비콘 없이도 안준환 담당 센서 이벤트 흐름을 확인할 수 있도록 만든 debug fixture 사용 가이드이다.

## 제공 파일

```txt
packages/mobile_sensors/fixtures/mock_beacon_sequence.json
packages/mobile_sensors/fixtures/sample_proximity_events.json
packages/mobile_sensors/docs/sensor_replay_guide.md
```

## 사용 목적

- 실기기 BLE 스캔 없이 `Stream<ProximityEvent>` 구독 로직을 확인한다.
- 앱 화면에서 `eventType` 분기, `beaconId`, `rssi`, `estimatedDistanceMeters`, `signalLevel`, `direction`, `timestamp`, `metadata` 표시를 점검한다.
- 오디오 cue 연결 전 단계에서 `BEACON_NEAR`, `APPROACHING_STOP`, `LEAVING_STOP`, `BEACON_LOST` 흐름을 고정 입력으로 재현한다.

## fixture 흐름

```txt
1. MEDIUM signal  -> 초기 frame, 이벤트 없음
2. CLOSE signal   -> BEACON_NEAR + APPROACHING_STOP
3. CLOSE signal   -> BEACON_NEAR + APPROACHING_STOP
4. MEDIUM signal  -> LEAVING_STOP
5. LOST signal    -> BEACON_LOST
```

## Dart 사용 예시

```dart
import 'dart:convert';
import 'package:mobi_mobile_sensors/mobi_mobile_sensors.dart';

final fixtureJson = jsonDecode(jsonString) as Map<String, Object?>;
final fixture = BeaconReplayFixture.fromJson(fixtureJson);
final runner = ProximityEventReplayRunner(fixture: fixture);

final events = await runner.collectEvents(
  targetBeaconId: 'MOBI_STOP_BEACON_001',
);

for (final event in events) {
  print(event.toJson());
}
```

## Passenger App 연결 기준

Passenger App 쪽에서는 실제 scanner 대신 replay runner 또는 `MockBeaconScanner`를 주입하여 아래 흐름을 확인하면 된다.

```txt
fixture JSON 읽기
-> BeaconReplayFixture.fromJson()
-> ProximityEventReplayRunner.collectEvents()
-> eventType별 UI/TTS 분기 확인
```

앱 코드에서 직접 구현해야 하는 부분은 다음이다.

```txt
- fixture 파일 읽기 위치 결정
- 화면 또는 로그 출력
- TTS 재생 여부 결정
- subscription cancel/dispose 처리
```

안준환 센서 패키지가 제공하는 부분은 다음이다.

```txt
- replay 가능한 BeaconSignal sequence
- expected sample proximity events
- ProximityEvent 변환 adapter
- Audio cue payload factory
- 권한/lifecycle 판단 helper
```

## sample_proximity_events.json 사용법

`sample_proximity_events.json`은 `mock_beacon_sequence.json`에서 기대되는 결과 payload를 사람이 바로 확인할 수 있도록 저장한 파일이다. 자동 테스트 입력이라기보다 앱 담당자가 화면 출력 예시와 eventType 분기 기준을 빠르게 확인하기 위한 sample output이다.

## 주의사항

- 이 fixture는 실제 BLE 실측값이 아니다.
- RSSI와 거리값은 앱 통합 smoke check용 고정 예시이다.
- 실기기 검증 전까지 정류장 현장의 벽, 사람, 비콘 설치 높이, 스마트폰 기종 차이는 반영되지 않는다.
- 실제 HRTF/3D 공간음향 렌더링은 이 패키지 범위가 아니다.
- Passenger App 코드는 이 섹션에서 직접 수정하지 않는다.
