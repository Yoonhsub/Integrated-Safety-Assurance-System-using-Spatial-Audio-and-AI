# Mobile Sensors Package - 안준환 담당 영역

`mobi_mobile_sensors`는 스마트폰 내장 방향/나침반 센서, BLE 비콘 수신, RSSI 기반 거리 추정 구조를 앱에서 사용할 수 있도록 분리한 패키지입니다.

이 패키지는 Flutter 앱 화면을 직접 구현하지 않습니다. 앱 팀은 이 패키지가 제공하는 모델, enum, scanner/sensor 인터페이스, 거리 추정 로직을 가져다 사용할 수 있습니다.

## 담당 범위

- BLE 비콘 스캔 구조
- RSSI 값 수집 구조
- RSSI smoothing/거리 추정 구조
- RSSI 기반 가까움/멀어짐 상태 계산
- 스마트폰 방향/나침반 센서값 수집 구조
- `BeaconSignal` / `ProximityEvent` / `DirectionReading` 데이터 모델
- `Stream<BeaconSignal>` → `Stream<ProximityEvent>` 변환 adapter
- `ProximityEvent` → `BoneConductionAudioCue` 안내 payload mapping
- `mobi_mobile_sensors.dart` public API export 정리
- 패키지 내부 예제 또는 로그 기반 검증 구조

## 4월 구현 범위

- 스마트폰 방향/나침반 센서값 읽기 skeleton
- BLE 비콘 스캔 skeleton
- RSSI 값 수집 인터페이스
- RSSI 기반 거리 추정 공식과 상태 분류 기준
- 비콘 데이터 모델과 서비스 인터페이스 모듈화
- 앱이 사용할 수 있는 public API export 유지

## 4월 제외 범위

- Flutter 사용자 앱 UI 직접 구현
- Flutter 기사 앱 UI 직접 구현
- 앱 화면에 BLE/RSSI/방향 센서 표시 UI 붙이기
- 외부 헤드트래킹 센서 통신
- 헤드트래킹 기반 공간음향
- 실제 HRTF/3D 오디오 렌더링
- backend/Firebase/public_data/AI Vision 직접 수정
- `packages/shared_contracts/**` 독단 수정

## Public API

`lib/mobi_mobile_sensors.dart`는 다음 파일을 public API로 export합니다.

```dart
export 'src/sensor_model_validation.dart'; // SensorModelValidation
export 'src/beacon_signal.dart';
export 'src/beacon_distance_estimator.dart';
export 'src/beacon_proximity_tracker.dart'; // BeaconProximityTracker, ProximityEvent
export 'src/proximity_event_stream.dart'; // ProximityEventStreamAdapter
export 'src/beacon_replay_fixture.dart'; // BeaconReplayFixture, ProximityEventReplayRunner
export 'src/beacon_scanner.dart';
export 'src/direction_sensor.dart';
export 'src/bone_conduction_audio_cue.dart';
export 'src/beacon_audio_cue_factory.dart';
export 'src/passenger_sensor_adapter.dart'; // PassengerSensorService, MobileSensorPassengerAdapter
```

앱 또는 다른 패키지는 내부 파일을 직접 import하기보다 아래처럼 패키지 entrypoint를 사용하는 것을 권장합니다.

```dart
import 'package:mobi_mobile_sensors/mobi_mobile_sensors.dart';
```

## BeaconSignal 계약

공식 JSON 구조는 `docs/rw/API_CONTRACTS.md`와 `packages/shared_contracts/events/event_types.json`을 기준으로 합니다.

```json
{
  "beaconId": "MOBI_BEACON_001",
  "rssi": -67,
  "estimatedDistanceMeters": 2.8,
  "signalLevel": "CLOSE",
  "lastDetectedAt": "2026-04-18T14:32:00+09:00"
}
```

필드 원칙은 다음과 같습니다.

- `beaconId`: 비콘 식별자
- `rssi`: 수신 신호 세기
- `estimatedDistanceMeters`: RSSI 기반 추정 거리, 추정 불가 시 `null` 가능
- `signalLevel`: `VERY_CLOSE`, `CLOSE`, `MEDIUM`, `FAR`, `LOST`
- `lastDetectedAt`: 마지막 감지 시각 ISO-8601 문자열

Dart enum 직렬화 값은 다음을 유지해야 합니다.

```txt
BeaconSignalLevel.veryClose -> VERY_CLOSE
BeaconSignalLevel.close     -> CLOSE
BeaconSignalLevel.medium    -> MEDIUM
BeaconSignalLevel.far       -> FAR
BeaconSignalLevel.lost      -> LOST
```


## BeaconScanner skeleton 계약

`BeaconScanner`는 BLE 스캔 결과를 `Stream<BeaconSignal>` 형태로 제공하는 패키지 내부 서비스 인터페이스입니다. 이 인터페이스는 앱 화면이나 버튼을 만들지 않고, 스캔 시작·중지 lifecycle과 `targetBeaconId` 필터링 책임만 분리합니다.

- `scan({String? targetBeaconId})`: 스캔 스트림을 시작하고, `targetBeaconId`가 있으면 해당 비콘 ID만 통과시킵니다.
- `stop()`: 진행 중인 스캔을 중지하는 lifecycle hook입니다.
- `isScanning`: scanner가 현재 스캔 중인지 확인하기 위한 상태값입니다.
- `UnimplementedBeaconScanner`: 실제 BLE 연동 전 skeleton입니다. `Stream.empty()` 반환은 현재 단계에서 오류가 아닙니다.
- `MockBeaconScanner`: 패키지 내부 예제·로그·smoke 검증에서 `BeaconSignal` 흐름과 `targetBeaconId` 필터링을 확인하기 위한 mock scanner입니다.

실제 `flutter_blue_plus` 연동에서는 스캔 결과를 `BeaconSignal`로 변환하되, 권한 안내 화면·스캔 버튼·결과 표시 UI는 Flutter 앱 담당 영역에서 처리해야 합니다.


## RSSI 거리 추정과 smoothing 기준

`BeaconDistanceEstimator`는 RSSI 값을 기반으로 초기 거리 추정값과 신호 레벨을 계산합니다. 이 계산은 현장 보정 전 기본 구조이며, 실제 서비스에서는 비콘 제조사, 설치 위치, 스마트폰 기종, 벽·사람 간섭에 따라 보정이 필요합니다.

기본 파라미터 의미는 다음과 같습니다.

- `txPower`: 기준 거리 1m에서 측정되는 RSSI 값입니다. 기본값 `-59`는 예시 기준값이며 비콘별 실측 보정이 필요합니다.
- `pathLossExponent`: RSSI가 거리 증가에 따라 약해지는 정도를 나타내는 환경 계수입니다. 기본값 `2.0`은 개방 공간에 가까운 초기값이며 실내 환경에 따라 달라질 수 있습니다.
- `estimateMeters(rssi)`: RSSI 기반 추정 거리를 meter 단위로 반환합니다. RSSI가 0 이상처럼 BLE 신호로 보기 어려운 값이면 추정 불가로 보고 `null`을 반환합니다.
- `classify(rssi)`: RSSI를 `VERY_CLOSE`, `CLOSE`, `MEDIUM`, `FAR`, `LOST` 중 하나로 분류합니다.

기본 RSSI 분류 기준은 다음과 같습니다. 이 기준은 확정 현장값이 아니라 초기 skeleton 기준입니다.

```txt
rssi >= -55  -> VERY_CLOSE
rssi >= -67  -> CLOSE
rssi >= -80  -> MEDIUM
rssi >= -92  -> FAR
rssi <  -92  -> LOST
```

`RssiMovingAverageSmoother`는 최근 RSSI 샘플의 단순 이동 평균을 계산합니다. 순간적으로 튀는 RSSI 값을 완화하기 위한 패키지 내부 helper이며, window 크기는 현장 테스트 후 조정할 수 있습니다.

```dart
final smoother = RssiMovingAverageSmoother(windowSize: 5);
final smoothedRssi = smoother.addSample(-69);
const estimator = BeaconDistanceEstimator();
final signal = estimator.buildSignal(
  beaconId: 'MOBI_BEACON_001',
  rssi: smoothedRssi,
  lastDetectedAt: DateTime.now(),
);

print(signal.toJson());
```

앱 화면에서 가까움/멀어짐을 어떻게 보여줄지는 Flutter 앱 담당 영역입니다. 이 패키지는 값 계산과 모델 변환만 담당합니다.



## V2 섹션 3 RSSI 거리 구간 추정 기준

섹션 3에서는 RSSI 값을 정밀한 meter 값 하나로 단정하기보다 Passenger App이 안정적으로 소비할 수 있는 거리 구간을 우선하도록 `BeaconDistanceZone`과 `BeaconDistanceEstimate`를 추가했습니다. 실제 버스 정류장 환경에서는 사람, 벽, 스마트폰 기종, 비콘 설치 높이에 따라 RSSI가 흔들리므로 화면이나 음성 안내에서는 구간 기반 판단을 기본으로 사용합니다.

앱 안내용 거리 구간은 다음 네 가지입니다.

```txt
BeaconDistanceZone.near    -> NEAR
BeaconDistanceZone.medium  -> MEDIUM
BeaconDistanceZone.far     -> FAR
BeaconDistanceZone.unknown -> UNKNOWN
```

기본 변환 기준은 다음과 같습니다. 이 값은 실측 보정 전 초기 기준입니다.

```txt
VERY_CLOSE / CLOSE -> NEAR
MEDIUM             -> MEDIUM
FAR                -> FAR
LOST               -> UNKNOWN

estimatedDistanceMeters <= 3.0m -> NEAR
estimatedDistanceMeters <= 8.0m -> MEDIUM
estimatedDistanceMeters >  8.0m -> FAR
null / invalid RSSI             -> UNKNOWN
```

`BeaconDistanceEstimator.estimate(rssi)`는 다음 값을 함께 반환합니다.

```txt
rssi
signalLevel
distanceZone
estimatedDistanceMeters
```

사용 예시는 다음과 같습니다.

```dart
const estimator = BeaconDistanceEstimator();
final estimate = estimator.estimate(-70);

print(estimate.distanceZone.toJsonValue());
print(estimate.estimatedDistanceMeters);
```

경계값 근처에서 안내가 계속 바뀌지 않도록 `stabilizeZone()`도 제공합니다. 예를 들어 3m 근처에서 `NEAR`와 `MEDIUM`이 반복 전환되는 경우, `zoneHysteresisMeters` 기본값 `0.75m` 범위 안에서는 이전 구간을 유지할 수 있습니다.

```dart
final candidate = estimator.classifyZoneFromMeters(3.1);
final stableZone = estimator.stabilizeZone(
  previousZone: BeaconDistanceZone.near,
  candidateZone: candidate,
  estimatedDistanceMeters: 3.1,
);
```

이 섹션의 핵심은 실제 거리가 정확히 몇 m인지 단정하는 것이 아니라, 앱과 오디오 cue가 사용할 `near`, `medium`, `far`, `unknown` 기준을 명확히 제공하는 것입니다. 실기기 보정 전까지 이 값은 확정 현장값이 아니라 mock/replay와 앱 연결을 위한 안정적인 초기 계약입니다.

## V2 섹션 2 Sensor 모델 검증 기준

섹션 2에서는 센서 도메인 모델이 앱에서 안전하게 소비될 수 있도록 null, unknown beacon, invalid RSSI, timestamp, distance 변환 기준을 명시하고 코드에 반영했습니다. 이 기준은 실제 BLE 연동을 의미하지 않고, JSON payload와 패키지 내부 모델 변환의 안전장치입니다.

### 공통 validation helper

`SensorModelValidation`은 다음 기준을 제공합니다.

```txt
unknownBeaconId: UNKNOWN_BEACON
valid RSSI: -127 이상 -1 이하의 정수
invalid RSSI: 0, 양수, -127보다 작은 값, NaN/Infinity, 소수점 RSSI
estimatedDistanceMeters: null 또는 0 이상 finite number
timestamp: 비어 있지 않은 ISO-8601 문자열
```

### null 값 처리

- `beaconId`가 null 또는 blank이면 `UNKNOWN_BEACON`으로 정규화합니다.
- `estimatedDistanceMeters`는 추정 불가 시 `null`을 허용합니다.
- `ProximityEvent.rssi`는 `BEACON_LOST` 같은 신호 상실 이벤트에서 `null`을 허용합니다.
- `direction`은 방향 센서값이 없으면 `null`을 허용합니다.
- `metadata`가 null이면 빈 object로 정규화합니다.

### unknown beacon 처리

비콘 ID를 알 수 없는 payload가 들어오더라도 앱이 즉시 crash하지 않도록 `UNKNOWN_BEACON` fallback을 사용합니다. 다만 실제 BLE scanner에서 beaconId를 얻지 못한 scan result는 의미 있는 위치 기준점이 아니므로 scanner 단계에서는 기존처럼 빈 ID를 통과시키지 않습니다.

### invalid RSSI 처리

- JSON 모델 parsing에서는 invalid RSSI를 `ArgumentError`로 거부합니다.
- live scan/buildSignal 경계에서는 invalid RSSI를 `LOST` sentinel인 `-127`로 낮춰 안전하게 처리합니다.
- smoothing helper는 invalid RSSI 샘플을 window에 넣지 않습니다.

### timestamp 처리

`lastDetectedAt`, `timestamp`, `DirectionReading.updatedAt`는 모두 ISO-8601 문자열이어야 합니다. 잘못된 문자열은 `ArgumentError`로 처리하여 앱 계층에서 invalid payload를 구분할 수 있게 했습니다.

### distance 변환 처리

`estimatedDistanceMeters`는 `null` 또는 0 이상 finite number만 허용합니다. RSSI가 invalid이면 거리 추정값은 만들지 않고 `LOST` 상태와 연결합니다. 이 기준은 정밀한 meter 값보다 앱에서 흔들리지 않는 안전한 상태 판단을 우선합니다.

## ProximityEvent 계약

`ProximityEvent`는 `BeaconSignal`과 선택적인 `DirectionReading`을 Passenger App이 바로 소비할 수 있는 이벤트 payload로 묶는 V2 섹션 1 기준 모델입니다. 이 모델은 실제 event stream 전환 로직이나 앱 화면을 만들지 않고, 섹션 5 이후 event stream 설계에서 사용할 필드 계약만 먼저 고정합니다.

기본 JSON 구조는 다음과 같습니다.

```json
{
  "eventType": "BEACON_NEAR",
  "beaconId": "MOBI_BEACON_001",
  "rssi": -67,
  "estimatedDistanceMeters": 2.8,
  "signalLevel": "CLOSE",
  "direction": {
    "headingDegrees": 132.5,
    "accuracy": "MEDIUM",
    "updatedAt": "2026-04-18T14:32:00+09:00"
  },
  "timestamp": "2026-04-18T14:32:01+09:00",
  "metadata": {}
}
```

필드 원칙은 다음과 같습니다.

- `eventType`: `BEACON_NEAR`, `BEACON_LOST`, `APPROACHING_STOP`, `LEAVING_STOP` 중 하나입니다.
- `beaconId`: 이벤트 기준이 된 비콘 식별자입니다.
- `rssi`: 이벤트 기준 RSSI 값입니다. 신호 상실 이벤트에서는 `null`을 허용합니다.
- `estimatedDistanceMeters`: RSSI 기반 추정 거리입니다. 추정 불가 또는 신호 상실이면 `null`을 유지합니다.
- `signalLevel`: 기존 `BeaconSignalLevel` JSON 값인 `VERY_CLOSE`, `CLOSE`, `MEDIUM`, `FAR`, `LOST`를 그대로 사용합니다.
- `direction`: 선택적인 스마트폰 방향 정보입니다. 방향 센서값이 없으면 `null`입니다.
- `timestamp`: 이벤트 생성 시각 ISO-8601 문자열입니다.
- `metadata`: 후속 섹션의 mock/replay/debug 정보를 담기 위한 선택 object입니다.

사용 예시는 다음과 같습니다.

```dart
final event = ProximityEvent.fromBeaconSignal(
  signal,
  eventType: ProximityEventType.beaconNear,
  direction: direction,
);

print(event.toJson());
```

주의할 점은 다음과 같습니다.

- 이 모델은 Passenger App이 소비할 수 있는 데이터 계약만 제공합니다.
- `apps/passenger_app/**` 화면, stream subscription, TTS 출력은 직접 수정하지 않습니다.
- 실제 event transition 판단은 섹션 5에서 `BEACON_NEAR`, `BEACON_LOST`, `APPROACHING_STOP`, `LEAVING_STOP` 흐름으로 별도 설계합니다.

## DirectionReading 계약

공식 JSON 구조는 다음과 같습니다.

```json
{
  "headingDegrees": 132.5,
  "accuracy": "MEDIUM",
  "updatedAt": "2026-04-18T14:32:00+09:00"
}
```

필드 원칙은 다음과 같습니다.

- `headingDegrees`: 0도 이상 360도 미만 범위로 정규화되는 방향값
- `accuracy`: `HIGH`, `MEDIUM`, `LOW`, `UNKNOWN`
- `updatedAt`: 갱신 시각 ISO-8601 문자열

`DirectionReading.normalizeHeadingDegrees()`는 플랫폼별 센서값이 음수나 360도 이상으로 들어와도 JSON 계약이 흔들리지 않도록 값을 `[0, 360)` 범위로 맞춥니다. 센서값 자체가 없거나 정확도를 판단할 수 없는 경우에는 `DirectionAccuracy.unknown`을 사용하고, 패키지 내부 fallback 모델은 `DirectionReading.unknown()`으로 표현합니다.

Dart enum 직렬화 값은 다음을 유지해야 합니다.

```txt
DirectionAccuracy.high    -> HIGH
DirectionAccuracy.medium  -> MEDIUM
DirectionAccuracy.low     -> LOW
DirectionAccuracy.unknown -> UNKNOWN
```

## DirectionSensor skeleton 계약

`DirectionSensor`는 스마트폰 내장 나침반 또는 방향 센서 결과를 `Stream<DirectionReading>` 형태로 제공하는 패키지 내부 서비스 인터페이스입니다. 이 인터페이스는 앱 화면을 만들지 않고, 센서 구독 시작·중지 lifecycle과 heading 모델 변환 책임만 분리합니다.

- `readings()`: 방향 센서값 스트림을 시작합니다.
- `stop()`: 진행 중인 센서 구독을 중지하는 lifecycle hook입니다.
- `isListening`: sensor가 현재 구독 중인지 확인하기 위한 상태값입니다.
- `UnimplementedDirectionSensor`: 실제 플랫폼 센서 연동 전 skeleton입니다. `Stream.empty()` 반환은 현재 단계에서 오류가 아닙니다.
- `MockDirectionSensor`: 패키지 내부 예제·로그·smoke 검증에서 `DirectionReading` 흐름과 heading 정규화를 확인하기 위한 mock sensor입니다.

실제 플랫폼 센서 연동에서는 센서 결과를 `DirectionReading`으로 변환하되, 권한 안내 화면·방향 표시 UI·공간음향 연동은 각각 Flutter 앱 또는 future module 담당 영역에서 처리해야 합니다.


## 추가 섹션 13 - 실제 BLE 비콘 스캔 연동 준비

`FlutterBlueBeaconScanner`는 `flutter_blue_plus`의 scan result를 `BeaconSignal` stream으로 변환하는 실제 BLE scanner 준비 구현체입니다. 이 구현체는 앱 화면을 만들지 않고, 패키지 내부에서 다음 흐름만 담당합니다.

- `FlutterBluePlus.startScan(timeout: scanTimeout)`으로 BLE 스캔 시작
- scan result의 광고 이름 또는 remote id를 `beaconId`로 변환
- 비콘별 `RssiMovingAverageSmoother` 적용
- `BeaconDistanceEstimator`로 거리 추정 및 `signalLevel` 분류
- `targetBeaconId`가 주어지면 해당 비콘만 통과
- `stop()` 호출 시 `FlutterBluePlus.stopScan()`으로 스캔 중지

```dart
final scanner = FlutterBlueBeaconScanner(
  scanTimeout: const Duration(seconds: 10),
  smoothingWindowSize: 5,
);

await for (final signal in scanner.scan(targetBeaconId: 'MOBI_BEACON_001')) {
  print(signal.toJson());
}
```

주의할 점은 다음과 같습니다.

- Android/iOS BLE 권한 요청 화면, manifest/plist 설정, Bluetooth 활성화 안내 UI는 Flutter 앱 담당 영역입니다.
- 이 패키지는 스캔 결과를 모델로 변환하는 역할만 담당합니다.
- 비콘 제조사별 UUID/manufacturer data 규칙이 확정되면 `BeaconIdResolver`를 주입해 `beaconId` 추출 방식을 바꿀 수 있습니다.
- 실기기 테스트 전에는 수신 RSSI와 거리값을 확정 현장값처럼 사용하면 안 됩니다.


## 추가 섹션 15 - 골전도 이어폰용 오디오 안내 cue 모델

`BoneConductionAudioCue`는 BLE 비콘 거리 상태를 골전도 이어폰 또는 앱 오디오 모듈에서 사용할 수 있는 짧은 안내 데이터로 바꾸기 위한 모델입니다. 이 모델은 실제 소리를 재생하지 않고, 앱의 TTS/알림음/진동/향후 오디오 모듈이 소비할 수 있는 cue 계약만 제공합니다.

주요 필드는 다음과 같습니다.

- `cueId`: 앱 또는 로그에서 cue를 구분하기 위한 ID
- `beaconId`: 안내 대상 비콘 ID
- `message`: TTS 또는 로그에서 사용할 짧은 안내 문장
- `signalLevel`: cue 생성에 사용된 `VERY_CLOSE`, `CLOSE`, `MEDIUM`, `FAR`, `LOST` 단계
- `estimatedDistanceMeters`: RSSI 기반 추정 거리, 추정 불가 시 `null`
- `proximityTrend`: `APPROACHING`, `MOVING_AWAY`, `STABLE`, `UNKNOWN` 중 하나, 판단하지 않았다면 `null`
- `urgency`: `LOW`, `MEDIUM`, `HIGH`, `CRITICAL` 안내 긴급도
- `repeatIntervalMs`: 반복 안내 권장 간격
- `shouldRepeat`: 반복 안내 대상 여부
- `createdAt`: cue 생성 시각

기본 cue 예시는 다음과 같습니다.

```txt
VERY_CLOSE -> 탑승 위치에 거의 도착했습니다.
CLOSE      -> 버스 문이 가까이에 있습니다.
MEDIUM     -> 조금 더 앞으로 이동하세요.
FAR        -> 목표 위치와 아직 떨어져 있습니다.
LOST       -> 비콘 신호가 약합니다. 주변을 다시 확인하세요.
```

사용 예시는 다음과 같습니다.

```dart
final cue = BoneConductionAudioCue.fromBeaconSignal(
  signal,
  proximityTrend: BeaconProximityTrend.approaching,
);

print(cue.toJson());
```

주의할 점은 다음과 같습니다.

- 골전도 이어폰은 현재 단계에서 일반 블루투스 오디오 출력 장치로 취급합니다.
- 이 패키지는 실제 TTS 재생, 블루투스 이어폰 연결 제어, 오디오 권한 처리, 앱 UI 버튼을 구현하지 않습니다.
- 헤드트래킹을 제외했기 때문에 머리 방향 변화에 따라 소리 방향이 실시간 보정되는 HRTF 기반 3D 공간음향은 구현하지 않습니다.
- 현재 구현은 비콘 거리 상태에 따라 어떤 안내를 낼지 결정하는 데이터 계약입니다.


## 추가 섹션 16 - 비콘 상태 기반 오디오 cue 생성기

`BeaconAudioCueFactory`는 `BeaconSignal`과 선택적인 `BeaconProximitySnapshot`을 입력받아 `BoneConductionAudioCue`를 생성하는 helper입니다. 이 단계는 골전도 이어폰에서 실제 소리를 재생하는 구현이 아니라, Flutter 앱의 TTS/알림음/오디오 모듈이 사용할 수 있는 안내 데이터 생성 책임만 분리합니다.

주요 역할은 다음과 같습니다.

- 단일 `BeaconSignal`을 거리 단계별 안내 cue로 변환
- `BeaconProximityTracker`의 `APPROACHING`, `MOVING_AWAY`, `STABLE`, `UNKNOWN` 추세를 cue에 반영
- 비콘 신호가 사라졌을 때 사용할 lost cue 생성
- `Stream<BeaconSignal>`을 `Stream<BoneConductionAudioCue>`로 변환하는 파이프라인 제공

사용 예시는 다음과 같습니다.

```dart
final tracker = BeaconProximityTracker();
const cueFactory = BeaconAudioCueFactory();

await for (final signal in scanner.scan(targetBeaconId: 'MOBI_BEACON_001')) {
  final snapshot = tracker.addSignal(signal);
  final cue = cueFactory.createCue(signal, proximitySnapshot: snapshot);
  print(cue.toJson());
}
```

stream 변환 형태로도 사용할 수 있습니다.

```dart
final cueStream = cueFactory.createCueStream(
  scanner.scan(targetBeaconId: 'MOBI_BEACON_001'),
  tracker: tracker,
);

await for (final cue in cueStream) {
  print(cue.message);
}
```

주의할 점은 다음과 같습니다.

- 이 factory는 실제 TTS 재생, Bluetooth 오디오 연결, 이어폰 출력 제어를 수행하지 않습니다.
- 헤드트래킹을 제외했기 때문에 머리 방향 기준의 HRTF/3D 공간음향 보정은 구현하지 않습니다.
- 현재 구현은 비콘 거리 상태와 접근 추세에 따라 어떤 안내를 낼지 결정하는 데이터 생성 계층입니다.
- 실제 앱에서 이 cue를 음성으로 읽거나 알림음으로 재생하는 작업은 Flutter 앱 또는 오디오 담당 영역에서 처리해야 합니다.


## V2 섹션 7 Audio Cue Mapping 설계

섹션 7에서는 섹션 5~6에서 만든 `ProximityEvent`를 Flutter Passenger App 또는 오디오 모듈이 소비할 수 있는 `BoneConductionAudioCue` payload로 변환하는 기준을 추가했습니다. 이 작업은 실제 TTS 재생, 블루투스 이어폰 연결 제어, HRTF/3D 공간음향 렌더링이 아니라 eventType별 안내 문구와 긴급도, 반복 간격을 정하는 mapping 계층입니다.

지원하는 eventType별 기본 mapping은 다음과 같습니다.

```txt
BEACON_NEAR      -> "정류장 근처입니다. 탑승 위치를 확인하세요." / urgency MEDIUM 또는 LOW
BEACON_LOST      -> "비콘 신호가 끊겼습니다. 주변을 다시 확인하세요." / urgency CRITICAL
APPROACHING_STOP -> "정류장에 가까워지고 있습니다." / urgency MEDIUM
LEAVING_STOP     -> "정류장에서 멀어지고 있습니다. 방향을 다시 확인하세요." / urgency HIGH
```

`BoneConductionAudioCue`에는 섹션 7 기준으로 `sourceEventType`을 추가했습니다. 기존 `BeaconSignal` 기반 cue에서는 null일 수 있고, `fromProximityEvent()`로 만든 cue에서는 `BEACON_NEAR`, `BEACON_LOST`, `APPROACHING_STOP`, `LEAVING_STOP` 중 하나가 들어갑니다. 앱은 이 값을 이용해 어떤 sensor event에서 안내가 발생했는지 로그와 TTS 분기에 사용할 수 있습니다.

사용 예시는 다음과 같습니다.

```dart
const cueFactory = BeaconAudioCueFactory();

final event = ProximityEvent.fromBeaconSignal(
  signal,
  eventType: ProximityEventType.beaconNear,
);

final cue = cueFactory.createCueForEvent(event);
print(cue.message);
print(cue.toJson());
```

stream 변환은 다음처럼 사용할 수 있습니다.

```dart
final eventAdapter = ProximityEventStreamAdapter(scanner: scanner);
const cueFactory = BeaconAudioCueFactory();

final cueStream = cueFactory.createCueStreamFromEvents(
  eventAdapter.watch(targetBeaconId: 'MOBI_STOP_BEACON_001'),
);

await for (final cue in cueStream) {
  print(cue.message);
}
```

주의할 점은 다음과 같습니다.

- 실제 소리를 재생하는 TTS 호출은 Passenger App 또는 오디오 출력 계층에서 처리합니다.
- 골전도 이어폰은 현재 단계에서 일반 블루투스 오디오 출력 장치로 취급합니다.
- `BUS_APPROACHING`, `OBSTACLE_DETECTED` 같은 이벤트는 현재 `ProximityEventType` 계약에 없으므로 이번 섹션에서 임의로 enum을 추가하지 않았습니다.
- 버스 접근 정보와 AI 장애물 감지는 다른 담당 영역 또는 shared contract 협의가 필요한 이벤트이므로, 이번 mapping은 안준환 담당 범위의 sensor proximity event 네 가지에 한정합니다.


## V2 섹션 8 Audio Cue Factory 검증

섹션 8에서는 섹션 7에서 추가한 `BeaconAudioCueFactory`가 앱에서 안정적으로 사용될 수 있는지 검증했습니다. 검증 범위는 트리거 프롬프트 기준의 `known event`, `unknown event`, `repeated event`, `priority conflict` 네 가지입니다.

검증 기준은 다음과 같습니다.

```txt
known event: BEACON_NEAR 같은 확정된 ProximityEventType은 정해진 message/urgency/repeat payload로 변환
unknown event: 현재 계약에 없는 문자열 event는 enum을 임의 추가하지 않고 fallback cue로 처리
repeated event: 짧은 시간 안에 반복되는 비치명 안내는 앱이 suppress 가능
priority conflict: 여러 cue가 동시에 발생하면 critical > high > medium > low 순서로 선택
```

섹션 8에서 보강한 factory helper는 다음과 같습니다.

```txt
createFallbackCueForUnknownEvent(): 알 수 없는 event 문자열을 안전한 warning cue로 변환
shouldSuppressRepeatedCue(): 같은 beacon/event가 cooldown 안에 반복될 때 중복 안내 억제 여부 판단
selectHighestPriorityCue(): cue 충돌 시 가장 높은 우선순위 cue 선택
createCueStreamFromEvents(... suppressRepeatedEvents: true): event stream 변환 중 반복 cue 억제 옵션 제공
```

테스트 파일은 아래 경로에 추가했습니다.

```txt
packages/mobile_sensors/test/audio_cue_factory_test.dart
```

이 검증은 실제 TTS 재생, 골전도 이어폰 연결, HRTF/3D 공간음향 렌더링을 수행하지 않습니다. 앱 또는 오디오 출력 계층이 사용할 cue payload와 queue 판단 기준만 제공합니다.


## V2 섹션 9 Passenger App 연결 adapter 기준

섹션 9에서는 `apps/passenger_app/**`를 직접 수정하지 않고, Passenger App이 센서 이벤트를 받을 수 있도록 `packages/mobile_sensors` 내부에 adapter 기준을 추가했습니다. 이 adapter는 앱 화면, 권한 요청 UI, 실제 TTS 호출을 구현하지 않고, 앱이 구독할 수 있는 stream/service interface만 제공합니다.

추가된 주요 API는 다음과 같습니다.

```txt
PassengerSensorService: 앱이 의존할 sensor service interface
MobileSensorPassengerAdapter: BeaconScanner를 proximity/audio cue stream으로 묶는 adapter
PassengerSensorAdapterConfig: targetBeaconId, 반복 cue 억제 기준 설정
PassengerSensorPermissionSnapshot: BLE/위치 권한과 기기 서비스 상태 snapshot
PassengerSensorPermissionStatus: READY, UNKNOWN, BLUETOOTH_PERMISSION_DENIED 등 권한 상태 enum
```

기본 연결 흐름은 다음과 같습니다.

```dart
final sensorService = MobileSensorPassengerAdapter(
  scanner: FlutterBlueBeaconScanner(),
  config: const PassengerSensorAdapterConfig(
    targetBeaconId: 'MOBI_STOP_BEACON_001',
    suppressRepeatedAudioCues: true,
  ),
  permissionProvider: () async {
    // 실제 권한 확인은 Passenger App에서 수행한다.
    return PassengerSensorPermissionSnapshot.ready();
  },
);

final permission = await sensorService.checkPermissionStatus();
if (permission.canStartScan) {
  final subscription = sensorService.watchProximityEvents().listen((event) {
    print(event.toJson());
  });

  await subscription.cancel();
  await sensorService.dispose();
}
```

오디오 안내 payload까지 필요한 경우에는 다음처럼 사용할 수 있습니다.

```dart
final cueSubscription = sensorService.watchAudioCues().listen((cue) {
  // 실제 TTS 호출, 알림음 재생, 골전도 이어폰 출력은 앱/오디오 계층에서 처리한다.
  print(cue.message);
});
```

권장 lifecycle은 다음과 같습니다.

```txt
initState 또는 viewModel start:
1. checkPermissionStatus()
2. watchProximityEvents() 또는 watchAudioCues() 구독

pause / route leave / logout:
1. StreamSubscription.cancel()
2. sensorService.stop()

dispose:
1. StreamSubscription.cancel()
2. sensorService.dispose()
```

권한 상태는 `PassengerSensorPermissionSnapshot`으로 표현합니다. 이 패키지는 Android/iOS 권한 요청 화면을 만들지 않으므로, 앱은 `permission_handler` 또는 플랫폼 API 결과를 `permissionProvider`로 주입해야 합니다. provider가 없으면 adapter는 `UNKNOWN`을 반환하며, 이는 패키지가 권한 상태를 모른다는 뜻입니다.

```txt
UNKNOWN: 패키지 내부에서 권한 상태를 확인하지 않음
READY: BLE/위치 권한과 기기 서비스가 준비됨
BLUETOOTH_PERMISSION_DENIED: Bluetooth 권한 거부
LOCATION_PERMISSION_DENIED: 위치 권한 거부
BLUETOOTH_OFF: Bluetooth 비활성화
LOCATION_OFF: 위치 서비스 비활성화
UNAVAILABLE: 기기나 플랫폼이 센서 기능을 제공하지 않음
```

자세한 Passenger App 소비 가이드는 아래 문서에 정리했습니다.

```txt
packages/mobile_sensors/docs/passenger_sensor_adapter_guide.md
```

주의할 점은 다음과 같습니다.

- Passenger App 코드는 이번 섹션에서 직접 수정하지 않았습니다.
- 실제 권한 요청 UI, 앱 화면 상태 관리, stream subscription 저장 위치는 Passenger App 담당 범위입니다.
- 실제 TTS 호출과 골전도 이어폰 출력 제어는 오디오 출력 계층에서 처리해야 합니다.
- `packages/shared_contracts/**`는 수정하지 않았습니다.

## 현재 구현 상태

현재 패키지는 GitHub-ready 스캐폴딩 단계입니다. 따라서 `UnimplementedBeaconScanner`와 `UnimplementedDirectionSensor`가 `Stream.empty()`를 반환하는 것은 오류가 아닙니다. 실제 BLE 스캔, 권한 처리, 현장 RSSI 보정값, 플랫폼별 센서 연결은 이후 구현 섹션에서 담당 범위 안에서 순차적으로 보강합니다.

`flutter_blue_plus`는 BLE 스캔 구현 준비를 위한 의존성입니다. 실제 앱 UI에서 스캔 버튼, 권한 안내 화면, 결과 화면을 붙이는 작업은 Flutter 앱 담당 영역입니다.

## 패키지 내부 사용 예시와 smoke 검증

아래 예시는 앱 UI 구현이 아니라 모델 계약과 거리 추정 로직 확인용입니다. 실제 앱 화면, 권한 안내, 버튼, 결과 렌더링은 Flutter 앱 담당 영역에서 처리해야 합니다.

```dart
import 'package:mobi_mobile_sensors/mobi_mobile_sensors.dart';

void main() {
  const estimator = BeaconDistanceEstimator();
  final rssi = -67;
  final signal = BeaconSignal(
    beaconId: 'MOBI_BEACON_001',
    rssi: rssi,
    estimatedDistanceMeters: estimator.estimateMeters(rssi),
    signalLevel: estimator.classify(rssi),
    lastDetectedAt: DateTime.now(),
  );

  final direction = DirectionReading(
    headingDegrees: -15,
    accuracy: DirectionAccuracy.medium,
    updatedAt: DateTime.now(),
  );

  print(signal.toJson());
  print(direction.toJson());
}
```

Dart SDK가 있는 환경에서는 아래 흐름을 별도 로컬 scratch 파일이나 Dart REPL 수준에서 확인할 수 있습니다. 정식 저장 파일을 추가하지 않는 이유는 이번 섹션의 목적이 앱 UI 구현이 아니라 public API 사용 경계와 smoke 검증 방법을 문서화하는 것이기 때문입니다.

확인 대상은 `MockBeaconScanner`, `RssiMovingAverageSmoother`, `BeaconDistanceEstimator`, `DirectionReading`, `MockDirectionSensor`입니다. 따라서 Flutter 사용자 앱 UI를 수정하거나 `apps/passenger_app/**`에 센서 화면을 붙이는 작업이 아닙니다.

```bash
cd packages/mobile_sensors
dart pub get
dart analyze
```

## 협업 경계

- `packages/mobile_sensors/**` 안의 모델·서비스·추정 로직은 안준환 담당입니다.
- `apps/passenger_app/**`, `apps/driver_app/**` 화면 구현은 직접 수정하지 않습니다.
- `future_modules/head_tracking/**`, `future_modules/spatial_audio/**`는 4월 실제 구현 대상이 아닙니다.
- shared contract enum 변경이 필요하면 직접 수정하지 않고 충돌 이슈로 기록한 뒤 팀원 협의를 요청합니다.

## 추가 섹션 14 - RSSI 안정화 및 가까워짐/멀어짐 판단

`BeaconProximityTracker`는 `BeaconSignal`의 최근 값을 비콘별로 보관하고, 거리 변화 또는 RSSI 변화량을 바탕으로 사용자가 목표 비콘에 가까워지는지 판단하는 helper입니다. 이 기능은 실제 공간음향 렌더링이 아니라, 골전도 이어폰 안내나 로그 기반 검증에서 사용할 수 있는 접근 추세 힌트를 제공하기 위한 패키지 내부 구조입니다.

판단 기준은 다음과 같습니다.

- `estimatedDistanceMeters`가 이전 값보다 작아지면 `APPROACHING`으로 판단합니다.
- `estimatedDistanceMeters`가 이전 값보다 커지면 `MOVING_AWAY`로 판단합니다.
- 거리 변화가 `distanceStableThresholdMeters` 이하이면 `STABLE`로 판단합니다.
- 거리값이 없을 때는 RSSI 변화량을 fallback으로 사용합니다.
- 최근 감지 시간이 `maxSignalAge`를 넘거나 signal level이 `LOST`이면 `UNKNOWN`으로 판단합니다.

```dart
final tracker = BeaconProximityTracker(
  distanceStableThresholdMeters: 0.4,
  rssiStableThreshold: 3,
  maxSignalAge: const Duration(seconds: 5),
);

final snapshot = tracker.addSignal(signal);
print(snapshot.toJson());
```

주의할 점은 다음과 같습니다.

- RSSI는 벽, 사람, 스마트폰 기종, 비콘 설치 위치에 따라 흔들릴 수 있으므로 `APPROACHING`/`MOVING_AWAY`는 정밀 위치 판정이 아니라 안내용 힌트입니다.
- `distanceStableThresholdMeters`, `rssiStableThreshold`, `maxSignalAge`는 현장 테스트 후 조정해야 합니다.
- 이 패키지는 가까워짐/멀어짐 상태를 계산할 뿐, 실제 TTS 재생이나 골전도 이어폰 연결 제어는 Flutter 앱 또는 오디오 담당 모듈에서 처리해야 합니다.

## V2 섹션 4 RSSI / smoothing 검증 기준

섹션 4에서는 섹션 3에서 만든 거리 구간 판단이 순간 RSSI 튐과 신호 끊김 상황에서 과도하게 흔들리지 않는지 검증했습니다. 검증 대상은 `RssiMovingAverageSmoother`와 `BeaconDistanceEstimator.classifyZone()` 조합입니다.

검증 기준은 다음 네 가지입니다.

```txt
연속 강한 신호: NEAR 구간 유지
연속 약한 신호: FAR 구간 유지
갑자기 튀는 신호: 단일 spike가 전체 안내 구간을 즉시 지배하지 않음
신호 끊김: invalid/missing RSSI가 반복되면 stale RSSI를 버리고 UNKNOWN으로 전환 가능
```

이를 위해 `RssiMovingAverageSmoother`에 다음 기준을 추가했습니다.

```txt
windowSize: 이동 평균에 사용할 최근 RSSI 샘플 개수
maxSingleSampleDelta: 단일 샘플이 현재 평균에서 한 번에 바뀔 수 있는 최대 RSSI 폭
lostResetThreshold: invalid/missing RSSI가 연속으로 몇 번 발생하면 window를 초기화할지 정하는 값
consecutiveLostSamples: 연속 신호 끊김 기록 횟수
recordSignalLost(): 스캔 결과 없음 또는 RSSI 신뢰 불가 상황을 기록하는 helper
```

사용 예시는 다음과 같습니다.

```dart
final smoother = RssiMovingAverageSmoother(
  windowSize: 5,
  maxSingleSampleDelta: 10,
  lostResetThreshold: 3,
);

smoother.addSample(-70);
smoother.addSample(-71);
smoother.addSample(-40); // sudden spike는 현재 평균 근처로 완화됨

smoother.recordSignalLost();
smoother.recordSignalLost();
smoother.recordSignalLost(); // stale RSSI window reset
```

섹션 4 검증 파일은 아래 경로에 추가했습니다.

```txt
packages/mobile_sensors/test/rssi_smoothing_test.dart
```

현재 작업 환경에는 Dart/Flutter SDK가 없어 `flutter test`를 직접 실행하지 못했습니다. 따라서 테스트 파일은 작성 완료 상태이며, 실제 실행 결과는 Flutter SDK가 있는 환경에서 확인해야 합니다.


## V2 섹션 5 Proximity Event Stream 설계

섹션 5에서는 BLE scanner가 제공하는 `Stream<BeaconSignal>`을 Passenger App이 바로 구독할 수 있는 `Stream<ProximityEvent>`로 변환하는 `ProximityEventStreamAdapter`를 추가했습니다. 이 adapter는 Flutter 앱 화면이나 권한 안내 UI를 직접 구현하지 않고, 센서 패키지 내부에서 event payload 구조만 제공합니다.

지원하는 eventType은 다음과 같습니다.

```txt
ProximityEventType.beaconNear      -> BEACON_NEAR
ProximityEventType.beaconLost      -> BEACON_LOST
ProximityEventType.approachingStop -> APPROACHING_STOP
ProximityEventType.leavingStop     -> LEAVING_STOP
```

기본 변환 기준은 다음과 같습니다.

```txt
BeaconSignalLevel.VERY_CLOSE / CLOSE -> BEACON_NEAR
BeaconSignalLevel.LOST               -> BEACON_LOST
BeaconProximityTrend.APPROACHING     -> APPROACHING_STOP
BeaconProximityTrend.MOVING_AWAY     -> LEAVING_STOP
```

사용 예시는 다음과 같습니다.

```dart
final adapter = ProximityEventStreamAdapter(
  scanner: MockBeaconScanner(mockSignals),
);

await for (final event in adapter.watch(targetBeaconId: 'MOBI_BEACON_001')) {
  print(event.toJson());
}
```

`ProximityEvent.metadata`에는 앱 디버깅과 후속 audio cue mapping에 필요한 `source`, `distanceZone`, `trend`, `isStale`, `rssiDelta`, `distanceDeltaMeters`가 포함됩니다. 실제 TTS 호출, 화면 표시, 앱 lifecycle 처리는 Passenger App 담당 영역이며 이 패키지는 이벤트 stream과 payload 계약만 제공합니다.

## V2 섹션 6 Event Stream mock/replay 검증

섹션 6에서는 실제 BLE 기기가 없어도 Passenger App 연동자가 센서 흐름을 재현할 수 있도록 replay fixture와 event transition 테스트 구조를 추가했습니다. 이 작업은 앱 화면을 직접 수정하지 않고, `packages/mobile_sensors/**` 내부에서 mock scanner와 replay helper만 제공합니다.

추가된 주요 구성은 다음과 같습니다.

```txt
BeaconReplayFrame          : 한 시점의 BeaconSignal + 선택적 DirectionReading
BeaconReplayFixture        : 여러 frame으로 구성된 mock beacon sequence
ProximityEventReplayRunner : fixture를 Stream<ProximityEvent>로 변환하는 test/helper runner
mock_beacon_sequence.json  : BEACON_NEAR / BEACON_LOST / APPROACHING_STOP / LEAVING_STOP 검증용 fixture
proximity_event_replay_test.dart : replay fixture 기반 event transition 테스트
```

fixture 경로는 다음과 같습니다.

```txt
packages/mobile_sensors/fixtures/mock_beacon_sequence.json
```

테스트 경로는 다음과 같습니다.

```txt
packages/mobile_sensors/test/proximity_event_replay_test.dart
```

fixture의 기본 전환 흐름은 다음과 같습니다.

```txt
MEDIUM signal  -> 초기값이므로 이벤트 없음
CLOSE signal   -> BEACON_NEAR + APPROACHING_STOP
CLOSE signal   -> BEACON_NEAR + APPROACHING_STOP
MEDIUM signal  -> LEAVING_STOP
LOST signal    -> BEACON_LOST
```

사용 예시는 다음과 같습니다.

```dart
final fixture = BeaconReplayFixture.fromJson(fixtureJson);
final runner = ProximityEventReplayRunner(fixture: fixture);
final events = await runner.collectEvents(
  targetBeaconId: 'MOBI_STOP_BEACON_001',
);

for (final event in events) {
  print(event.toJson());
}
```

이 fixture는 실제 BLE 수신값을 가장하지 않습니다. 목적은 실기기 전 단계에서 앱 팀이 event stream 구독, eventType 분기, direction payload 유무, lost event 처리를 검증할 수 있게 하는 것입니다. 실제 BLE 스캔과 권한 처리는 이후 lifecycle/권한 검증 섹션과 실기기 테스트에서 별도로 확인해야 합니다.


## V2 섹션 9 Passenger Sensor Adapter 기준

섹션 9에서는 `apps/passenger_app/**`를 직접 수정하지 않고, Passenger App이 sensor event와 audio cue payload를 구독할 수 있는 adapter 기준을 추가했습니다.

추가된 주요 구성은 다음과 같습니다.

```txt
PassengerSensorService: 앱이 의존할 sensor service interface
MobileSensorPassengerAdapter: BeaconScanner를 proximity/audio cue stream으로 연결하는 adapter
PassengerSensorAdapterConfig: targetBeaconId, repeated cue 억제 설정
PassengerSensorPermissionSnapshot: BLE/위치 권한과 기기 서비스 상태 snapshot
PassengerSensorPermissionStatus: UNKNOWN, READY, BLUETOOTH_PERMISSION_DENIED 등 권한 상태 enum
```

세부 연결 기준은 아래 문서에 정리했습니다.

```txt
packages/mobile_sensors/docs/passenger_sensor_adapter_guide.md
```

## V2 섹션 10 앱 lifecycle / 권한 처리 검증 기준

섹션 10에서는 BLE 권한, 위치 권한, 앱 background/foreground, 스캔 중지/재개 상황을 실기기 전 단계에서 검증·문서화했습니다. 이 패키지는 앱 권한 요청 UI를 직접 만들지 않고, 앱이 권한 상태와 lifecycle 상태를 주입하면 어떤 sensor 동작을 선택해야 하는지 판단할 수 있는 policy helper를 제공합니다.

추가된 주요 구성은 다음과 같습니다.

```txt
PassengerSensorLifecyclePhase: FOREGROUND, BACKGROUND, PAUSED, RESUMED, RESTARTED, DISPOSED
PassengerSensorLifecycleAction: START_SCAN, KEEP_SCANNING, STOP_SCAN, RESUME_SCAN, USE_MOCK_REPLAY, SHOW_PERMISSION_RATIONALE, DO_NOTHING
PassengerSensorLifecycleDecision: 권한/lifecycle 조합에 따른 앱 동작 결정 payload
PassengerSensorLifecyclePolicy: 권한 snapshot과 lifecycle phase를 받아 scan 시작/중지/재개 기준을 결정하는 helper
```

검증 기준은 다음과 같습니다.

```txt
권한 없음/미확인: live scan 시작 금지, mock/replay fallback 또는 앱 권한 확인 필요
권한 거부: live scan 시작 금지, 권한 안내 UI 필요
앱 background/paused: subscription cancel 후 scanner stop 권장
앱 resumed/restarted: 권한 재확인 후 subscription 재생성 또는 scan 재개
dispose: subscription cancel 후 adapter dispose
```

사용 예시는 다음과 같습니다.

```dart
final policy = PassengerSensorLifecyclePolicy();
final permission = await sensorService.checkPermissionStatus();
final decision = policy.decide(
  permission: permission,
  phase: PassengerSensorLifecyclePhase.resumed,
  wasScanning: scanner.isScanning,
);

if (decision.shouldStartScan) {
  subscription = sensorService.watchProximityEvents().listen(handleEvent);
}

if (decision.shouldStopScan) {
  await subscription.cancel();
  await sensorService.stop();
}
```

세부 가이드는 아래 문서에 정리했습니다.

```txt
packages/mobile_sensors/docs/passenger_sensor_lifecycle_guide.md
```

섹션 10 검증 파일은 아래 경로에 추가했습니다.

```txt
packages/mobile_sensors/test/passenger_sensor_lifecycle_test.dart
```

현재 작업 환경에는 Dart/Flutter SDK가 없어 `flutter test`를 직접 실행하지 못했습니다. 따라서 lifecycle policy 테스트 파일은 작성 완료 상태이며, 실제 실행 결과는 Flutter SDK가 있는 환경에서 확인해야 합니다.

## V2 섹션 11 Sensor Debug Fixture 정리

섹션 11에서는 다른 팀원이 실제 BLE 비콘 없이도 센서 이벤트 흐름을 재현할 수 있도록 debug fixture를 정리했습니다. 목적은 Passenger App 담당자가 센서 패키지를 직접 실행하거나 실기기를 준비하지 않아도 `BEACON_NEAR`, `APPROACHING_STOP`, `LEAVING_STOP`, `BEACON_LOST` 흐름을 확인할 수 있게 하는 것입니다.

정리된 산출물은 다음과 같습니다.

```txt
packages/mobile_sensors/fixtures/mock_beacon_sequence.json
packages/mobile_sensors/fixtures/sample_proximity_events.json
packages/mobile_sensors/docs/sensor_replay_guide.md
packages/mobile_sensors/test/proximity_event_replay_test.dart
```

`mock_beacon_sequence.json`은 replay 입력입니다. `sample_proximity_events.json`은 해당 입력을 `ProximityEventReplayRunner`로 변환했을 때 기대되는 sample output입니다. 앱 담당자는 `sensor_replay_guide.md`를 참고하여 실제 scanner 대신 fixture를 주입하고 eventType별 UI/TTS 분기를 점검할 수 있습니다.

기본 replay 흐름은 다음과 같습니다.

```txt
MEDIUM signal  -> 이벤트 없음
CLOSE signal   -> BEACON_NEAR + APPROACHING_STOP
CLOSE signal   -> BEACON_NEAR + APPROACHING_STOP
MEDIUM signal  -> LEAVING_STOP
LOST signal    -> BEACON_LOST
```

사용 예시는 다음과 같습니다.

```dart
final fixture = BeaconReplayFixture.fromJson(fixtureJson);
final runner = ProximityEventReplayRunner(fixture: fixture);
final events = await runner.collectEvents(
  targetBeaconId: 'MOBI_STOP_BEACON_001',
);
```

이 fixture는 실측 BLE 데이터가 아니라 통합 smoke check용 고정 입력입니다. 실제 RSSI 보정, 권한 요청 UI, 앱 lifecycle subscription 보관, 실제 TTS/골전도 이어폰 출력은 각 담당 모듈과 실기기 검증 단계에서 확인해야 합니다.
