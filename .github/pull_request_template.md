<!-- PR 올리기 전 #48 자가검수 체크리스트를 반드시 통과하세요.
     AI 에이전트로 자동 검수하려면 #48 본문의 프롬프트를 복붙해서 실행하세요. -->

## 변경 요약
<!-- 무엇을/왜 바꿨는지. 아래 체크리스트의 "변경파일=설명 일치"를 위해 실제 변경만 정확히 적기(허위 금지). -->

## 관련 이슈
- closes #

---

## ✅ PR 전 자가검수 (해당 항목 전부 체크되어야 머지 가능 · 상세/에이전트 프롬프트: #48)

### 경로 / 구조
- [ ] 변경 파일이 올바른 경로(`mobi-smart-transport-ai/...`)에 있음
- [ ] 이중 중첩 폴더(`apps/passenger_app/passenger_app/`) 없음 / 잘못된 새 `pubspec.yaml` 없음

### 프론트 (Flutter 변경 시)
- [ ] `cd mobi-smart-transport-ai/apps/passenger_app && flutter analyze` → **No issues found!**
- [ ] `flutter build web --release --base-href /app/ --dart-define=MOBI_API_BASE_URL=https://mobi.35.232.72.197.nip.io --dart-define=MOBI_WEB_DEMO_ORIGIN_ENABLED=true` 성공
- [ ] 추가한 JS는 `web/index.html`에, 에셋은 `pubspec.yaml`에 등록함
- [ ] `apps/passenger_app/build/` 산출물 미커밋

### 백엔드 (FastAPI 변경 시)
- [ ] `python -m compileall -q mobi-smart-transport-ai/backend/api/app` 통과
- [ ] 새 라우터는 `app/main.py`에 `import` + `include_router(...)` 등록함
- [ ] 로컬 uvicorn + curl로 신규/기존 endpoint 200 확인
- [ ] 관련 테스트 추가/통과, 기존 endpoint 회귀 없음

### Git / PR 위생
- [ ] 최신 `main` 반영함, `revert` / revert-of-revert 아님
- [ ] **변경 파일 목록 = 위 "변경 요약"과 정확히 일치** (`git diff --name-only origin/main...HEAD`)
- [ ] `.env` / 시크릿 / `.venv` / 빌드물 미커밋

### 협업 / 배포 규칙
- [ ] VM 직접 접근·업로드 안 함 (PR만 — 권한 차단됨)
- [ ] "VM 검증 완료" 공지 전 VM 안 건드림 / 배포는 배포자 1명
