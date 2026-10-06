# AI Vision 안내 후보 전달 명세 — 합의 전 후보

## 목적과 경계

개발자 B(AI Vision)는 카메라 프레임에서 관측한 버스를 화면 기준의 방향·상대
거리·변화 상태로 해석해 전달한다. 이 문서는 그 전달 형식을 팀이 합의하기 위한
후보이며, 아직 `packages/shared_contracts`에 등록된 정식 공통 계약이 아니다.

AI Vision은 다음을 **전달한다**.

- 지원 클래스(`bus`)와 모델 신뢰도
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

`candidates`가 빈 배열이면 이 프레임에서 **신뢰 가능한 버스 안내 후보가 없었다**는
뜻이다. “버스가 절대 없다” 또는 “안전하다”는 판정이 아니다.

## 소비자에게 필요한 해석

| 필드 | 소비자(Context/음성)가 알아야 할 의미 |
| --- | --- |
| `direction` | 휴대폰 카메라 화면 기준 방향이다. 사용자 머리 방향을 반영하려면 Head Tracking 정보와 결합해야 한다. |
| `relativeDistance` | 실제 거리(m)가 아니라 bbox 면적의 상대 단계다. 임계값은 기기·화각·현장 영상으로 보정해야 한다. |
| `motion` | 이전 **분석 프레임**과의 크기 변화다. 프레임 누락·카메라 이동의 영향을 받을 수 있다. |
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

## 팀 합의가 필요한 항목

1. 정식 계약을 `packages/shared_contracts`에 등록할 담당자와 시점
2. 화면 방향과 Head Tracking 방향을 합성하는 기준
3. `NEAR` 또는 `APPROACHING`일 때의 SAL 위험도와 음성 반복 억제 정책
4. `bus_door`, 장애물 등 다른 클래스가 추가될 때 후보 배열의 우선순위 기준
