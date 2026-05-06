# docs/read/COMMIT_CONVENTION.md

> 이 문서는 MOBI 프로젝트의 커밋 메시지 규칙을 정의한다.  
> 모든 팀원과 AI 에이전트는 커밋 메시지를 통해 **누가, 어떤 섹션에서, 무엇을 변경했는지** 명확히 남겨야 한다.

---

## 1. 기본 형식

```txt
type(scope): summary
```

예시:

```txt
feat(hyunseok): add FastAPI health check route
docs(common): add dependency management rules
fix(junhwan): correct RSSI distance state labels
```

---

## 2. type 규칙

| type | 의미 | 예시 |
|---|---|---|
| `feat` | 기능 추가 | API, UI, 센서 기능, 공공데이터 모듈 추가 |
| `fix` | 버그 수정 | 검토/패치 섹션에서 발견한 오류 수정 |
| `docs` | 문서 작성/수정 | README, 보고서, 프롬프트, 규칙 문서 |
| `refactor` | 구조 개선 | 동작 변경 없이 코드 구조 개선 |
| `test` | 테스트 추가/수정 | 검증 코드, mock 테스트 |
| `chore` | 설정/환경/잡무 | .gitignore, 패키지 설정, CI 설정 |
| `style` | 포맷팅 | 코드 포맷, 들여쓰기, 주석 정리 |
| `revert` | 되돌리기 | 이전 커밋 되돌림 |

---

## 3. scope 규칙

scope에는 담당자 또는 공통 영역을 넣는다.

| scope | 의미 |
|---|---|
| `hyunseok` | 심현석 담당 백엔드/Firebase/지오펜싱/FCM/매칭 |
| `hyunseop` | 윤현섭 담당 Flutter UI/STT/TTS/접근성 |
| `junhwan` | 안준환 담당 BLE/RSSI/센서 |
| `doseong` | 김도성 담당 공공데이터/API/AI 비전 |
| `common` | 공통 문서, shared contracts, GitHub 설정 |
| `docs` | 문서 전반 |
| `infra` | Firebase, 환경 설정, GitHub Actions 등 인프라 |

가능하면 개인 작업은 본인 scope를 사용한다.

---

## 4. summary 작성 규칙

summary는 영어 또는 한국어 모두 가능하지만, 짧고 구체적으로 작성한다.

좋은 예:

```txt
feat(hyunseok): add ride request schema skeleton
docs(doseong): document public data mock response
fix(hyunseop): patch accessibility label for voice button
feat(junhwan): add RSSI signal level enum
```

나쁜 예:

```txt
update
fix bug
작업함
최종
수정
```

---

## 5. 섹션 번호를 포함하는 권장 방식

섹션 작업 커밋에는 본문 또는 summary에 섹션 번호를 포함하는 것을 권장한다.

예시:

```txt
feat(hyunseok): section 02 add backend base skeleton
fix(hyunseop): section 07 patch safe status card rendering
docs(doseong): section 03 update public data debug report
```

또는 커밋 본문에 작성한다.

```txt
Section: 02
Owner: 심현석
Files:
- backend/api/app/main.py
- backend/api/app/api/routes/ride_requests.py
```

---

## 6. 커밋 본문 권장 형식

커밋이 단순하지 않다면 본문에 아래 내용을 추가한다.

```txt
Section:
Owner:
Changed:
Reason:
Validation:
Related docs:
Related conflict:
```

예시:

```txt
feat(hyunseok): section 04 add geofence response schema

Section: 04
Owner: 심현석
Changed:
- Added geofence request/response skeleton
- Added SAFE/WARNING/DANGER status enum placeholder

Reason:
- 윤현섭 UI rendering requires stable geofence response contract.

Validation:
- python scripts/validate_architecture.py

Related docs:
- docs/rw/선행작업의존성 정리.md DEP-APR-002

Related conflict:
- None
```

---

## 7. AI 에이전트 커밋 규칙

AI 에이전트가 생성한 커밋은 커밋 본문에 다음 정보를 남기는 것을 권장한다.

```txt
AI-Agent: 심현석의 에이전트
Instruction-Source:
- docs/read/프로젝트 4월분 개발에 관한 공통 프롬프트(AI 절대필독!).md
- docs/read/심현석의 에이전트 필독사항.md
```

예시:

```txt
docs(common): add contributing rules

AI-Agent: 공통 아키텍처 작업
Instruction-Source:
- docs/read/AGENT_REQUIRED_READING.md
- docs/read/CONTRIBUTING.md
```

---

## 8. 충돌 이슈 관련 커밋

충돌 ID 형식: `CONFLICT-YYYYMMDD-HHMM-담당자명-번호`


충돌 이슈와 관련된 커밋은 반드시 충돌 번호를 명시한다.

```txt
fix(hyunseok): resolve CONFLICT-20260418-1530-심현석-002 ride request status mismatch
docs(common): record CONFLICT-20260418-1600-공통-001 dependency blocker
```

커밋 본문에는 다음을 작성한다.

```txt
Related conflict: CONFLICT-20260418-1530-심현석-002
Resolution:
- ...
```

---

## 9. 선행작업 의존성 관련 커밋

`docs/rw/선행작업의존성 정리.md`를 최신화하는 커밋은 다음 형식을 권장한다.

```txt
docs(common): mark DEP-APR-001 prerequisite complete
```

본문 예시:

```txt
Dependency:
- DEP-APR-001

Updated:
- 김도성 섹션 2, 3: (미구현) → (구현완료_2026-04-18 14:32)

Follow-up:
- 윤현섭 섹션 6, 7 can verify actual mock JSON before rendering.
```

---

## 10. 커밋 쪼개기 원칙

하나의 커밋에는 하나의 의미 있는 변경만 담는다.

좋은 예:

```txt
feat(hyunseok): add Firebase service skeleton
docs(hyunseok): update section 02 progress log
```

나쁜 예:

```txt
feat(hyunseok): add backend, edit Flutter UI, update public data module
```

다른 팀원 영역을 함께 수정해야 한다면 커밋하기 전에 `docs/rw/충돌 이슈.md`에 기록한다.

---

## 11. 금지 커밋 메시지

아래와 같은 메시지는 금지한다.

```txt
update
final
진짜최종
last
fix
temp
working
asdf
```

이유:

```txt
- 변경 내용을 추적하기 어려움
- 캡스톤 기여도 확인에 불리함
- AI 병렬 개발 중 책임 소재가 흐려짐
```

---

## 12. 예시 모음

### 심현석

```txt
feat(hyunseok): section 02 add FastAPI skeleton
feat(hyunseok): section 04 add geofence check contract
fix(hyunseok): section 05 patch geofence status enum
docs(hyunseok): section 03 update debug report
```

### 윤현섭

```txt
feat(hyunseop): section 02 add passenger app shell
feat(hyunseop): section 04 add voice input screen
fix(hyunseop): section 07 patch bus arrival card mock rendering
docs(hyunseop): update final report template
```

### 안준환

```txt
feat(junhwan): section 04 add BLE scan service skeleton
feat(junhwan): section 06 add RSSI distance estimator
fix(junhwan): section 07 patch signal level thresholds
docs(junhwan): update mobile sensor README
```

### 김도성

```txt
docs(doseong): section 02 document public data API candidates
feat(doseong): section 04 add bus arrival parser skeleton
feat(doseong): section 06 add low floor normalization
docs(doseong): section 10 add lightweight AI model research
```

### 공통

```txt
docs(common): add branch strategy
docs(common): add pull request rules
chore(common): update gitignore
refactor(common): organize shared contracts folder
```

---

## 13. 최종 원칙

```txt
커밋은 작게.
메시지는 명확하게.
담당자와 섹션을 드러내게.
충돌 이슈는 숨기지 않게.
문서 최신화도 커밋으로 남기게.
```
