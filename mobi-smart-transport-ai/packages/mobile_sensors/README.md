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

- `headingDegrees`: 0도 이상 360도 미만 범위로 해석되는 방향값
- `accuracy`: `HIGH`, `MEDIUM`, `LOW`, `UNKNOWN`
- `updatedAt`: 갱신 시각 ISO-8601 문자열

Dart enum 직렬화 값은 다음을 유지해야 합니다.

```txt
DirectionAccuracy.high    -> HIGH
DirectionAccuracy.medium  -> MEDIUM
DirectionAccuracy.low     -> LOW
DirectionAccuracy.unknown -> UNKNOWN
```

## 현재 구현 상태

현재 패키지는 GitHub-ready 스캐폴딩 단계입니다. 따라서 `UnimplementedBeaconScanner`와 `UnimplementedDirectionSensor`가 `Stream.empty()`를 반환하는 것은 오류가 아닙니다. 실제 BLE 스캔, 권한 처리, 현장 RSSI 보정값, 플랫폼별 센서 연결은 이후 구현 섹션에서 담당 범위 안에서 순차적으로 보강합니다.

`flutter_blue_plus`는 BLE 스캔 구현 준비를 위한 의존성입니다. 실제 앱 UI에서 스캔 버튼, 권한 안내 화면, 결과 화면을 붙이는 작업은 Flutter 앱 담당 영역입니다.

## 패키지 내부 사용 예시

아래 예시는 앱 UI 구현이 아니라 모델 계약과 거리 추정 로직 확인용입니다.

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

  print(signal.toJson());
}
```

## 협업 경계

- `packages/mobile_sensors/**` 안의 모델·서비스·추정 로직은 안준환 담당입니다.
- `apps/passenger_app/**`, `apps/driver_app/**` 화면 구현은 직접 수정하지 않습니다.
- `future_modules/head_tracking/**`, `future_modules/spatial_audio/**`는 4월 실제 구현 대상이 아닙니다.
- shared contract enum 변경이 필요하면 직접 수정하지 않고 충돌 이슈로 기록한 뒤 팀원 협의를 요청합니다.
