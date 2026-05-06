# docs/rw/MODULE_OWNERSHIP.md

> MOBI 프로젝트의 모듈별 소유권과 수정 권한을 정의한다.  
> 생성형 AI를 활용한 병렬 개발에서 가장 중요한 원칙은 **자기 담당 영역을 명확히 지키고, 타 팀원 영역을 임의로 수정하지 않는 것**이다.

---

## 1. 핵심 원칙

```txt
- 소유권의 공식 기준본은 module_ownership.json이다.
- docs/rw/MODULE_OWNERSHIP.md와 .github/CODEOWNERS는 module_ownership.json을 사람이 읽거나 GitHub가 적용하기 위한 파생 문서이다.
- 세 파일이 충돌할 경우 module_ownership.json을 우선한다.
```



```txt
- 각 팀원은 자기 소유 모듈을 우선 수정한다.
- 타 팀원 소유 모듈 수정이 필요하면 docs/rw/충돌 이슈.md에 기록한다.
- 공통 모듈은 단독 판단으로 변경하지 않는다.
- shared contract 변경은 관련 팀원 모두에게 영향을 준다.
```

---

## 2. 소유권 요약

| 경로 | 주 담당자 | 보조/참조 | 설명 |
|---|---|---|---|
| `apps/passenger_app` | 윤현섭 | 심현석, 김도성 | 사용자 Flutter 앱 |
| `apps/driver_app` | 윤현섭 | 심현석 | 기사 Flutter 앱 |
| `backend/api` | 심현석 | 윤현섭, 김도성 | FastAPI 백엔드 |
| `services/public_data` | 김도성 | 심현석, 윤현섭 | 공공데이터 API 연동/표준화 |
| `packages/mobile_sensors` | 안준환 | 윤현섭 | BLE/RSSI/방향 센서 |
| `packages/shared_contracts` | 공통 | 전원 | API/DB/이벤트 계약 |
| `ai_vision` | 김도성 | 윤현섭, 심현석 | AI 비전 준비 |
| `future_modules/head_tracking` | 공통/보류 | 안준환 | 향후 헤드트래킹 placeholder. 4월 구현 금지 |
| `future_modules/spatial_audio` | 공통/보류 | 안준환 | 향후 공간음향 placeholder. 4월 구현 금지 |
| `infrastructure/firebase` | 심현석 | 공통 검토 | Firebase/FCM/DB |
| `docs` | 공통 | 전원 | 기준 문서 |
| `.github` | 공통 | 전원 | GitHub 협업 설정 |
| `scripts` | 공통 | 전원 | 검증/관리 스크립트 |

---

## 3. 팀원별 세부 소유권

## 3.1 심현석

주요 소유 경로:

```txt
backend/api
infrastructure/firebase
packages/shared_contracts 중 geofence/ride request/backend 계약 관련 영역
```

담당 기능:

```txt
- FastAPI 서버
- Firebase Admin SDK 연결
- 지오펜싱 판별 API
- FCM 알림 전송 구조
- rideRequests 매칭 파이프라인
- 김도성 공공데이터 결과를 받을 백엔드 인터페이스
```

수정 금지 또는 주의 영역:

```txt
- services/public_data 직접 구현 금지
- apps/passenger_app, apps/driver_app 직접 수정 금지
- packages/mobile_sensors 직접 수정 금지
- ai_vision 직접 수정 금지
```

---

## 3.2 윤현섭

주요 소유 경로:

```txt
apps/passenger_app
apps/driver_app
```

담당 기능:

```txt
- 사용자 앱 UI
- 기사용 앱 UI
- STT/TTS 인터페이스
- 접근성 UI
- 버스 도착 정보 렌더링
- 안전 상태 UI
- 탑승 요청 UI
```

수정 금지 또는 주의 영역:

```txt
- backend/api 내부 로직 직접 수정 금지
- Firebase DB 스키마 직접 변경 금지
- services/public_data 표준 JSON 임의 변경 금지
- packages/mobile_sensors 내부 로직 직접 수정 금지
```

---

## 3.3 안준환

주요 소유 경로:

```txt
packages/mobile_sensors
```

담당 기능:

```txt
- BLE 비콘 스캔
- 특정 비콘 ID 필터링
- RSSI 거리 추정
- 신호 상태값 분류
- 스마트폰 방향 센서 인터페이스
```

4월 구현 금지:

```txt
- 헤드트래킹 센서 통신
- 헤드트래킹 기반 공간음향
- Flutter UI 직접 수정
- FastAPI/Firebase 직접 수정
- 공공데이터 API 직접 구현
```

---

## 3.4 김도성

주요 소유 경로:

```txt
services/public_data
ai_vision
```

담당 기능:

```txt
- 공공데이터 API 조사
- 버스 도착 정보 조회 모듈
- 저상버스 여부 필터링
- 혼잡도 표준화
- 표준 응답 JSON/mock 데이터
- AI 비전 데이터 수집 계획
- 모바일 경량 AI 모델 리서치
```

수정 금지 또는 주의 영역:

```txt
- backend/api 직접 수정 금지
- Firebase DB 스키마 직접 변경 금지
- Flutter UI 직접 수정 금지
- packages/mobile_sensors 직접 수정 금지
- 비콘 거리 테스트 계획 담당 아님
- 공간음향 방향 테스트 계획 담당 아님
```

---

## 4. 공통 소유 영역

## 4.1 packages/shared_contracts

공통 계약 영역이다.

수정 전 확인:

```txt
[ ] 어떤 팀원에게 영향이 있는가
[ ] docs/rw/API_CONTRACTS.md와 일치하는가
[ ] docs/rw/DATA_SCHEMA.md와 일치하는가
[ ] docs/rw/충돌 이슈.md 기록이 필요한가
```

단독 변경 금지 항목:

```txt
- rideRequests status enum
- busArrivals 표준 필드
- geofence status enum
- error response format
```

---

## 4.2 docs

문서 영역이다.

문서 기준과 참고 문서:

```txt
docs/01_요구사항명세서.md                         # 공식 SRS 기준 문서
docs/02_4월_개인별_구현범위_수정안.md             # 4월 역할/범위 기준 문서
docs/00_원본_모비_프로젝트_계획서.docx             # 제출/공유용 참고 원문
docs/01_요구사항명세서.docx                       # 제출/공유용 참고 문서
```

`.docx` 파일은 전체 배경 이해를 위한 보조 원문으로 보존하되, 공식 계약·정합성 판단은 markdown 문서와 machine-readable schema를 우선한다.

문서 수정 원칙:

```txt
- 기준 문서는 삭제하지 않는다.
- 충돌하는 내용은 최신 실행 문서를 우선한다.
- 문서 우선순위는 docs/read/CONTRIBUTING.md를 따른다.
```



## 4.2.1 공통 문서 제한적 최신화 예외

아래 두 파일은 공통 보호 영역에 속하지만, 섹션 종료 기록과 선행작업 상태 관리를 위해 제한적 수정 예외를 둔다.

```txt
docs/rw/공통 진행사항.md
- 각 에이전트는 자기 팀원 기록 공간만 수정 가능
- 다른 팀원 기록 공간, 문서 구조, 공통 규칙은 단독 수정 금지

docs/rw/선행작업의존성 정리.md
- 각 에이전트는 자신이 완료한 선행 섹션의 상태/산출물 정보만 제한적으로 최신화 가능
- 의존성 구조, 후행 조건, 타 팀원 섹션 상태는 단독 수정 금지
```

위 예외는 소유권 변경이 아니라 운영 기록 최신화를 위한 최소 권한이다. 공통 규칙이나 의존성 구조 변경이 필요하면 `docs/rw/충돌 이슈.md`에 기록하고 합의 후 수정한다.

---

## 4.3 .github

GitHub 협업 설정 영역이다.

포함:

```txt
.github/CODEOWNERS
.github/pull_request_template.md
```

수정 시 주의:

```txt
팀원 전체 협업 방식에 영향을 주므로 공통 변경으로 취급한다.
```

---

## 5. 타 팀원 영역 수정이 필요한 경우

다음 절차를 따른다.

```txt
1. 즉시 작업 중단
2. docs/rw/충돌 이슈.md에 기록
3. 관련 팀원 명시
4. 사용자에게 해당 팀원과 논의 요청
5. 합의 후 PR로 수정
```

사용자에게 전달할 문구:

```txt
**현재 작업은 [팀원명] 담당 영역을 수정해야 하므로 더 이상 진행할 수 없습니다. 반드시 [팀원명]에게 연락하여 이 이슈를 논의한 뒤 진행해야 합니다.**
```

---

## 6. 선행작업 의존성 관련 소유권

선행 작업 의존성이 있는 경우, 후행 담당자는 선행 담당자의 파일을 직접 고치지 않는다.

예시:

```txt
김도성 섹션 2, 3 → 윤현섭 섹션 6, 7
```

윤현섭 에이전트는 김도성의 `services/public_data` mock JSON이 없거나 부실하더라도 직접 수정하지 않는다.  
문제가 있으면 `docs/rw/충돌 이슈.md`에 기록한다.

---

## 7. module_ownership.json과의 관계

`module_ownership.json`은 도구나 스크립트가 읽기 쉬운 구조화된 소유권 정보이다.  
`docs/rw/MODULE_OWNERSHIP.md`는 사람이 읽기 쉬운 설명 문서이다.

두 문서가 충돌하면 다음 절차를 따른다.

```txt
1. docs/rw/충돌 이슈.md에 기록
2. 어떤 문서가 최신 기준인지 확인
3. 두 문서를 함께 수정
4. PR로 병합
```

---

## 8. 최종 원칙

```txt
내 폴더만 고친다.
공통 계약은 협의한다.
선행 작업물은 기다린다.
부족하면 직접 고치지 말고 기록한다.
소유권이 애매하면 멈춘다.
```
