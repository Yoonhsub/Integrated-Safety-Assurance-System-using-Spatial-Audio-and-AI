# docs/read/BRANCH_STRATEGY.md

> 이 문서는 MOBI 프로젝트의 Git 브랜치 운영 전략을 정의한다.  
> 팀원과 AI 에이전트는 브랜치를 만들기 전에 반드시 이 문서를 확인해야 한다.

---

## 1. 핵심 원칙

```txt
main 직접 push 금지
작업 단위는 섹션 또는 문서 1개 중심
브랜치 이름만 봐도 담당자와 작업 범위가 드러나야 함
타 팀원 담당 영역을 건드리는 브랜치는 생성 전 docs/rw/충돌 이슈.md 기록
```

모든 기능 개발은 Pull Request를 통해 병합한다.

---

## 2. 기본 브랜치 구조

```txt
main
└── feature/{owner}-section-{number}-{short-description}
└── fix/{owner}-section-{number}-{short-description}
└── docs/{owner-or-common}-{short-description}
└── chore/{owner-or-common}-{short-description}
```

`main` 브랜치는 항상 병합 가능한 기준 상태를 유지한다.

---

## 3. owner 표기 규칙

브랜치명에는 담당자를 영문 소문자로 표기한다.

| 팀원 | owner 표기 | 담당 범위 |
|---|---|---|
| 심현석 | `hyunseok` | FastAPI, Firebase, 지오펜싱, FCM, rideRequests |
| 윤현섭 | `hyunseop` | Flutter 사용자 앱, 기사용 앱, STT/TTS, 접근성 UI |
| 안준환 | `junhwan` | BLE, RSSI, 스마트폰 방향 센서, mobile_sensors |
| 김도성 | `doseong` | 공공데이터 API, 저상버스 필터링, AI 비전 준비 |
| 공통 | `common` | 공통 문서, shared contracts, GitHub 설정, 아키텍처 |

---

## 4. 브랜치 타입

### 4.1 feature

새로운 기능 또는 섹션 구현용 브랜치.

```txt
feature/{owner}-section-{number}-{short-description}
```

예시:

```txt
feature/hyunseok-section-02-backend-base
feature/hyunseop-section-04-passenger-home-ui
feature/junhwan-section-06-rssi-distance
feature/doseong-section-02-public-data-mock
```

---

### 4.2 fix

검토/패치 섹션에서 발견된 문제 수정용 브랜치.

```txt
fix/{owner}-section-{number}-{short-description}
```

예시:

```txt
fix/hyunseok-section-03-backend-base-review
fix/hyunseop-section-07-safe-status-rendering
fix/junhwan-section-05-ble-scan-permission
fix/doseong-section-07-low-floor-normalization
```

---

### 4.3 docs

문서 작성/수정용 브랜치.

```txt
docs/{owner-or-common}-{short-description}
```

예시:

```txt
docs/common-api-contracts
docs/common-dependency-rules
docs/hyunseok-debug-report
docs/doseong-public-data-research
```

---

### 4.4 chore

환경 설정, 패키지 설정, CI 설정 등 기능 구현이 아닌 관리 작업용 브랜치.

```txt
chore/{owner-or-common}-{short-description}
```

예시:

```txt
chore/common-gitignore-update
chore/common-github-template
chore/hyunseok-backend-env-example
```

---

## 5. 섹션 번호 표기

섹션 번호는 두 자리 숫자로 표기한다.

```txt
section-01
section-02
section-03
...
section-12
```

예시:

```txt
feature/hyunseok-section-02-backend-base
fix/hyunseop-section-07-rendering-review
```

섹션 번호 없이 기능 브랜치를 만들지 않는다.  
문서나 공통 설정 작업처럼 섹션과 직접 관련 없는 경우에만 `docs/common-*`, `chore/common-*` 형식을 사용한다.

---

## 6. 브랜치 생성 전 체크리스트

브랜치를 만들기 전에 아래를 확인한다.

```txt
[ ] 내가 어느 팀원의 에이전트인지 명확하다.
[ ] 자기 팀원 에이전트 필독사항을 읽었다.
[ ] docs/rw/선행작업의존성 정리.md를 확인했다.
[ ] 현재 섹션이 순서상 맞다.
[ ] 타 팀원 소유 폴더를 수정하지 않는다.
[ ] 선행 작업물이 필요한 경우 구현완료 상태인지 확인했다.
[ ] 충돌 가능성이 있으면 docs/rw/충돌 이슈.md에 먼저 기록했다.
```

---

## 7. 브랜치별 작업 범위 제한

하나의 브랜치는 가능한 한 하나의 섹션만 다룬다.

허용:

```txt
feature/hyunseok-section-04-geofence-api
→ 심현석 섹션 4 구현 파일과 관련 문서만 수정
```

비허용:

```txt
feature/hyunseok-section-04-geofence-api
→ 심현석 섹션 4 구현 + 윤현섭 UI 수정 + 김도성 mock JSON 수정
```

타 팀원 영역 수정이 필요하면 해당 작업은 멈추고 `docs/rw/충돌 이슈.md`에 기록한다.

---

## 8. 선행작업 의존성 관련 브랜치 규칙

`docs/rw/선행작업의존성 정리.md`에 후행 섹션으로 명시된 작업을 수행할 때는 브랜치 생성 전 선행 섹션 상태를 확인한다.

예시:

```txt
김도성 섹션 2, 3 (미구현)
→ 윤현섭 섹션 6, 7 (미구현)
```

이 경우 윤현섭 에이전트는:

```txt
- 섹션 1~5는 순차적으로 진행 가능
- 섹션 6, 7 중 실제 버스 정보 렌더링 확정은 김도성 섹션 2, 3 완료 후 진행
- 선행 미구현 상태에서 routeId, busNo, arrivalMinutes 등 표준 필드 임의 확정 금지
```

---

## 9. 병합 순서 권장

4월 구현범위 기준 권장 병합 순서는 다음과 같다.

```txt
1. 공통 문서 및 아키텍처 기준선
2. 김도성 섹션 2~3: 공공데이터 API 조사 및 mock 기준
3. 심현석 섹션 2~5: 백엔드/Firebase/지오펜싱 기본 계약
4. 윤현섭 섹션 2~7: 앱 shell, STT/TTS, 접근성, mock/API 렌더링
5. 안준환 섹션 2~7: 센서 패키지, BLE, RSSI 거리 추정
6. 심현석 섹션 6~9: FCM, rideRequests
7. 윤현섭 섹션 8~9: 기사 앱 요청 UI
8. 김도성 섹션 6~11: 저상버스/혼잡도 표준화 및 AI 비전 준비
9. 심현석 섹션 10~11: 공공데이터 연동 인터페이스
10. 각 팀원 섹션 12 최종 보고
```

이 순서는 권장 순서이며, 독립 작업은 병렬 진행할 수 있다.  
다만 강한 선행작업 의존성이 있는 경우에는 `docs/rw/선행작업의존성 정리.md`를 우선한다.

---

## 10. 금지 브랜치명

아래와 같은 브랜치명은 금지한다.

```txt
test
final
my-work
update
fix
new
temp
feature/app
feature/backend
```

이유:

```txt
- 담당자가 드러나지 않음
- 섹션 번호가 없음
- 작업 범위가 불명확함
- 병합 시 추적이 어려움
```

---

## 11. 삭제 가능한 브랜치

PR이 병합된 후에는 원격 브랜치를 삭제해도 된다.  
단, 관련 PR과 커밋 기록이 GitHub에 남아 있어야 한다.

삭제 전 확인:

```txt
[ ] PR이 main에 병합됨
[ ] docs/rw/공통 진행사항.md가 최신화됨
[ ] 디버그 리포트 또는 최종 보고서가 필요한 경우 작성됨
[ ] 충돌 이슈가 있으면 해결 또는 미해결 상태가 기록됨
```

---

## 12. 최종 원칙

```txt
브랜치는 작게 만든다.
브랜치명에는 담당자와 섹션을 넣는다.
main에는 직접 push하지 않는다.
선행 의존성이 있으면 먼저 확인한다.
충돌 가능성이 있으면 브랜치를 키우지 말고 기록한다.
```
