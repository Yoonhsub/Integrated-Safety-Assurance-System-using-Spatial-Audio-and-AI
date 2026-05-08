# docs/rw/SETUP.md

> MOBI 프로젝트를 로컬에서 처음 실행하거나 개발하기 위한 환경 설정 문서이다.  
> 이 문서는 4명의 팀원이 GitHub에서 프로젝트를 내려받은 뒤, 각자 담당 파트 개발을 시작하기 전에 확인해야 하는 최소 실행/설정 절차를 정리한다.

---

## 1. 사전 준비

필수 설치 항목:

```txt
- Git
- Python 3.10 이상 권장
- Flutter SDK
- Dart SDK
- Node.js, 선택 사항
- Firebase CLI, 선택 사항
- Android Studio 또는 VS Code
```

선택 설치 항목:

```txt
- Google Cloud CLI
- Postman 또는 Insomnia
- Firebase Emulator Suite
```

---

## 2. 저장소 클론

```bash
git clone <repository-url>
cd mobi-smart-transport-ai
```

저장소를 받은 뒤 가장 먼저 확인해야 할 문서:

```txt
docs/read/AGENT_REQUIRED_READING.md
docs/read/CONTRIBUTING.md
docs/read/BRANCH_STRATEGY.md
docs/rw/선행작업의존성 정리.md
docs/02_4월_개인별_구현범위_수정안.md
```

AI 에이전트를 사용할 경우, 해당 에이전트에게 반드시 다음을 먼저 읽게 한다.

```txt
docs/read/프로젝트 4월분 개발에 관한 공통 프롬프트(AI 절대필독!).md
자기 팀원의 에이전트 필독사항.md
docs/rw/선행작업의존성 정리.md
docs/rw/충돌 이슈.md
docs/rw/공통 진행사항.md
```

---

## 3. 환경변수 파일 준비

루트의 `.env.example`을 복사하여 `.env`를 만든다.

```bash
cp .env.example .env
```

Windows PowerShell 예시:

```powershell
Copy-Item .env.example .env
```

각 환경변수의 의미는 `docs/rw/ENVIRONMENT_VARIABLES.md`를 따른다.

주의:

```txt
.env 파일은 절대 GitHub에 커밋하지 않는다.
Firebase service account key도 절대 공개 저장소에 올리지 않는다.
```

---

## 4. 아키텍처 검증

프로젝트 구조가 깨졌는지 확인한다.

```bash
python scripts/validate_architecture.py
```

정상 출력 예시:

```txt
Architecture validation: PASS
```

이 검증이 실패하면 PR 병합 전 반드시 원인을 확인한다.

---

## 5. 백엔드 FastAPI 실행 준비

담당자: 심현석

예상 경로:

```txt
backend/api
```

가상환경 생성:

```bash
cd backend/api
python -m venv .venv
```

macOS/Linux:

```bash
source .venv/bin/activate
```

Windows PowerShell:

```powershell
.\.venv\Scripts\Activate.ps1
```

의존성 설치:

```bash
pip install -r requirements.txt
```

서버 실행 예시:

```bash
uvicorn app.main:app --reload
```

4월 MVP 기준 백엔드 확인 항목:

```txt
- /health 응답
- Firebase Admin SDK 연결 skeleton
- /geofence/check contract
- /ride-requests contract
- FCM service skeleton
```

---

## 6. Flutter 사용자 앱 실행 준비

담당자: 윤현섭

예상 경로:

```txt
apps/passenger_app
```

실행 절차:

```bash
cd apps/passenger_app
flutter pub get
flutter run
```

4월 MVP 기준 확인 항목:

```txt
- 앱 실행
- 사용자 앱 메인 화면
- STT 버튼 또는 인터페이스
- TTS 버튼 또는 인터페이스
- 접근성 라벨
- mock/API 데이터 렌더링 구조
```

---

## 7. Flutter 기사용 앱 실행 준비

담당자: 윤현섭

예상 경로:

```txt
apps/driver_app
```

실행 절차:

```bash
cd apps/driver_app
flutter pub get
flutter run
```

4월 MVP 기준 확인 항목:

```txt
- 기사 앱 shell
- 탑승 요청 카드 UI
- 정적 예시 데이터
- rideRequests contract와 충돌하지 않는 구조
```

---

## 8. 공공데이터 모듈 실행 준비

담당자: 김도성

예상 경로:

```txt
services/public_data
```

예상 실행 절차:

```bash
cd services/public_data
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

Windows PowerShell:

```powershell
cd services/public_data
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
```

4월 MVP 기준 확인 항목:

```txt
- 공공데이터 API 조사 문서
- API key 환경변수 참조
- bus arrival mock JSON
- lowFloor boolean 표준화
- congestion LOW/NORMAL/HIGH/UNKNOWN 표준화
```

---

## 9. 모바일 센서 패키지 실행 준비

담당자: 안준환

예상 경로:

```txt
packages/mobile_sensors
```

4월 MVP 기준 확인 항목:

```txt
- BLE scan service skeleton
- beacon signal model
- RSSI distance estimator
- signal level enum
- compass/direction sensor interface
```

주의:

```txt
4월에는 헤드트래킹 구현을 하지 않는다.
헤드트래킹 관련 구현은 future_modules/head_tracking에 프레임만 둔다.
```

---

## 10. AI 비전 준비 영역

담당자: 김도성

예상 경로:

```txt
ai_vision
```

4월 MVP 기준 확인 항목:

```txt
- 데이터 수집 계획
- 탐지 클래스 후보
- YOLO/MobileNet/TFLite 등 모델 리서치
- 2학기 파이프라인 초안
```

4월에는 실제 모델 학습/추론 코드나 Flutter/백엔드 실시간 통합을 구현하지 않는다. 이 영역의 목표는 데이터 수집 계획, 라벨링 기준, 모델 후보 리서치, 2학기 파이프라인 초안 작성이다.

---

## 11. Firebase 설정

Firebase 설정은 주로 심현석 담당이다.

관련 경로:

```txt
infrastructure/firebase
```

확인 항목:

```txt
- Realtime Database schema
- Firebase rules 초안
- FCM 설정 메모
- service account key 경로는 .env에서만 관리
```

금지:

```txt
- serviceAccountKey.json Git 커밋
- Firebase Admin private key 공개
- 실제 사용자 개인정보 테스트 데이터 업로드
```

---

## 12. GitHub 작업 흐름

작업 전:

```bash
git pull origin main
git checkout -b feature/{owner}-section-{number}-{short-description}
```

예시:

```bash
git checkout -b feature/hyunseok-section-02-backend-base
```

작업 후:

```bash
git status
git add .
git commit -m "feat(hyunseok): section 02 add backend base skeleton"
git push origin feature/hyunseok-section-02-backend-base
```

그다음 GitHub에서 Pull Request를 생성한다.

자세한 규칙:

```txt
docs/read/BRANCH_STRATEGY.md
docs/read/COMMIT_CONVENTION.md
docs/read/PULL_REQUEST_RULES.md
docs/read/CONTRIBUTING.md
```

---

## 13. 섹션 종료 시 필수 절차

각 팀원의 에이전트가 섹션을 끝내면 다음을 수행한다.

```txt
1. 관련 파일 저장
2. docs/rw/공통 진행사항.md의 자기 기록 공간 최신화
3. 검토/패치 섹션이면 자기 디버그 리포트 최신화
4. docs/rw/선행작업의존성 정리.md 관련 섹션이면 상태 최신화
5. 충돌이 있으면 docs/rw/충돌 이슈.md 기록
6. 사용자에게 GitHub 업로드 권유 문구 출력
```

필수 문구:

```txt
**지금 섹션 X 끝났습니다. 캡스톤 과목 점수 획득 및 충돌 병목 최소화를 위해 지금까지 진행상황 깃헙에 올리시는 것을 권유드립니다.**
```

---

## 14. 문제 발생 시

### 14.1 의존성 문제

선행 작업물이 없으면:

```txt
1. docs/rw/선행작업의존성 정리.md 확인
2. docs/rw/충돌 이슈.md에 기록
3. 사용자에게 선행 담당 팀원에게 먼저 작업 요청 안내
```

### 14.2 타 팀원 파일 수정 필요

```txt
1. 작업 중단
2. docs/rw/충돌 이슈.md 기록
3. 관련 팀원 이름 명시
4. 사용자에게 협의 요청
```

### 14.3 실행 오류

```txt
1. 오류 메시지 기록
2. 자기 담당 영역인지 확인
3. 자기 영역이면 패치
4. 타 팀원 영역이면 docs/rw/충돌 이슈.md 기록
```

---

## 15. 최종 확인

GitHub 업로드 전 확인:

```txt
[ ] 필수 문서가 모두 존재한다.
[ ] .env가 커밋되지 않는다.
[ ] service account key가 커밋되지 않는다.
[ ] python scripts/validate_architecture.py 통과
[ ] docs/rw/README.md가 존재한다.
[ ] docs/read/CONTRIBUTING.md가 존재한다.
[ ] .github/CODEOWNERS가 존재한다.
[ ] .github/pull_request_template.md가 존재한다.
```

---

## 16. 최종 원칙

```txt
먼저 문서를 읽는다.
자기 영역만 실행한다.
환경변수는 숨긴다.
검증 후 커밋한다.
문제는 기록한다.
GitHub에는 자주 올린다.
```
---

## 17. 검증 및 테스트 실행

백엔드 pytest는 전역 pytest 플러그인 자동 로딩 때문에 로컬 환경에 따라 불필요하게 느려지거나 멈출 수 있다.
이 패키지의 기본 스캐폴딩 검증에서는 다음 명령을 표준으로 사용한다.

Unix/macOS/Linux:

```bash
cd backend/api
PYTHONDONTWRITEBYTECODE=1 PYTEST_DISABLE_PLUGIN_AUTOLOAD=1 python -m pytest -q -p no:cacheprovider
```

Windows PowerShell:

```powershell
cd backend/api
$env:PYTHONDONTWRITEBYTECODE="1"
$env:PYTEST_DISABLE_PLUGIN_AUTOLOAD="1"
python -m pytest -q -p no:cacheprovider
Remove-Item Env:PYTHONDONTWRITEBYTECODE
Remove-Item Env:PYTEST_DISABLE_PLUGIN_AUTOLOAD
```

예상 출력:

```txt
5 passed
```
