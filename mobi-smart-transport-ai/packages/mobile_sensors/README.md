# Mobile Sensors Package - 안준환 담당 영역

`mobi_mobile_sensors`는 스마트폰 내장 방향/나침반 센서, BLE 비콘 수신, RSSI 기반 거리 추정 구조를 앱에서 사용할 수 있도록 분리한 패키지입니다.

이 패키지는 Flutter 앱 화면을 직접 구현하지 않습니다. 앱 팀은 이 패키지가 제공하는 모델, enum, scanner/sensor 인터페이스, 거리 추정 로직을 가져다 사용할 수 있습니다.

## 담당 범위

- BLE 비콘 스캔 구조
- RSSI 값 수집 구조
- RSSI smoothing/거리 추정 구조
- RSSI 기반 가까움/멀어짐 상태 계산
- 스마트폰 방향/나침반 센서값 수집 구조
- `BeaconSignal` / `DirectionReading` 데이터 모델
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
export 'src/beacon_signal.dart';
export 'src/beacon_distance_estimator.dart';
export 'src/beacon_scanner.dart';
export 'src/direction_sensor.dart';
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
