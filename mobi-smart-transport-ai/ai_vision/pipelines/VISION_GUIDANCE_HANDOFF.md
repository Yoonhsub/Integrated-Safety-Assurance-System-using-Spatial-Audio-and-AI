# AI Vision 안내 후보 전달 명세 — 합의 전 후보

## 목적과 경계

AI Vision은 카메라 프레임에서 관측한 버스·버스 문을 화면 기준의 방향·상대
거리·변화 상태로 해석해 전달한다. 이 문서는 그 전달 형식을 팀이 합의하기 위한
후보이며, 아직 `packages/shared_contracts`에 등록된 정식 공통 계약이 아니다.

AI Vision은 다음을 **전달한다**.

- 지원 클래스(`bus`, `bus_door`)와 모델 신뢰도
- 카메라 화면 기준 `LEFT/CENTER/RIGHT`
- bbox 크기 기준 `FAR/MEDIUM/NEAR`
- 이전 분석 프레임과 비교한 `UNKNOWN/APPROACHING/STABLE/RECEDING`

AI Vision은 다음을 **결정하지 않는다**.

- 실제 미터 거리와 충돌 위험도
- 사용자에게 재생할 한국어 문장
- 안내 우선순위·반복 억제·공간 음향 출력 방향
- SAL 등급과 backend 저장·알림 정책

## Payload

```json
{
  "schemaVersion": "0.1.0-proposed",
  "frameId": "UUID v4",
  "capturedAt": "RFC3339 timestamp",
  "candidates": [
    {
      "classId": "bus",
      "direction": "LEFT | CENTER | RIGHT",
      "relativeDistance": "FAR | MEDIUM | NEAR",
      "motion": "UNKNOWN | APPROACHING | STABLE | RECEDING",
      "confidence": 0.0,
      "normalizedArea": 0.0
    }
  ]
}
```

`bus_door` 후보는 검출 박스의 70% 이상이 같은 프레임의 `bus` 박스에 포함될 때만
전달한다. 문 방향은 문 박스를 기준으로, 상대 거리·변화 상태는 문을 포함한 버스
차체 박스를 기준으로 계산한다.

`candidates`가 빈 배열이면 이 프레임에서 **신뢰 가능한 안내 후보가 없었다**는
뜻이다. “버스가 절대 없다” 또는 “안전하다”는 판정이 아니다.

## 소비자에게 필요한 해석

| 필드 | 소비자(Context/음성)가 알아야 할 의미 |
| --- | --- |
| `direction` | 휴대폰 카메라 화면 기준 방향이다. 사용자 머리 방향을 반영하려면 Head Tracking 정보와 결합해야 한다. |
| `relativeDistance` | 실제 거리(m)가 아니라 bbox 면적의 상대 단계다. `bus_door`는 문을 포함한 버스 차체 면적을 쓴다. 임계값은 기기·화각·현장 영상으로 보정해야 한다. |
| `motion` | 이전 **분석 프레임**과의 크기 변화다. `bus_door`는 문을 포함한 버스 차체의 변화를 쓴다. 프레임 누락·카메라 이동의 영향을 받을 수 있다. |
| `confidence` | 객체 분류 신뢰도다. 위험도나 안내 우선순위가 아니다. |
| `normalizedArea` | 화면 전체 대비 bbox 면적이다. 소비자가 디버깅·정책 보정에 사용할 수 있다. |

## 실제 검증 예시

CC0 공개 버스 영상의 15.6초 지점에서 생성된 후보는 다음 의미였다.

```json
{
  "classId": "bus",
  "direction": "LEFT",
  "relativeDistance": "NEAR",
  "motion": "APPROACHING",
  "confidence": 0.9086,
  "normalizedArea": 0.3796
}
```

Context/음성 담당자는 이를 바탕으로 안내 여부·문장·재생 방향을 정할 수 있지만,
이 후보 하나만으로 사용자를 즉시 위험하다고 판단해서는 안 된다.

## Context·Audio 연동용 고정 예시

실제 버스 문 모델을 공개 테스트 이미지에 실행해 얻은 형태를 고정 예시로 남겼다.
`fixtures/bus_door_guidance_candidate.json`을 Context·Audio 연동 테스트의 입력으로
사용할 수 있다. 예시에는 같은 프레임의 `bus`와 `bus_door` 후보가 함께 들어 있다.

- AI Vision이 제공하는 값: 객체 종류, 화면 방향, 상대 거리, 변화 상태, 신뢰도
- Context·Audio가 정하는 값: 실제 음성 문장, 공간 음향, 위험도, 우선순위, 반복 억제

따라서 이 예시를 받았을 때 소비자 모듈은 `bus_door`가 있다는 사실만으로 음성을
즉시 재생하지 않는다. 사용자 상태와 다른 안내 후보를 함께 고려해 정책을 적용한다.
이 파일은 합의·통합 검증용 fixture이며 정식 공통 계약은 아니다.

## 팀 합의가 필요한 항목

1. 정식 계약을 `packages/shared_contracts`에 등록할 담당자와 시점
2. 화면 방향과 Head Tracking 방향을 합성하는 기준
3. `NEAR` 또는 `APPROACHING`일 때의 SAL 위험도와 음성 반복 억제 정책
4. `bus`와 `bus_door`가 동시에 후보일 때 음성 안내 우선순위·반복 억제 기준
5. 이후 장애물 등 다른 클래스가 추가될 때 후보 배열의 우선순위 기준
