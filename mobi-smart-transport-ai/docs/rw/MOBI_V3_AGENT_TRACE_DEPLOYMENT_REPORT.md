# MOBI V3 Agent Trace Deployment Report

## 작업 완료 요약

- FastAPI 응답에 `traceId`와 `trace`를 추가했다.
- `AgentTraceRecorder`가 단계별 상태, provider, operation, duration, 안전 payload를 기록한다.
- API 키, authorization, token, 비밀번호, URL, 정밀 좌표가 trace에 노출되지 않도록 백엔드 redaction을 적용했다.
- Flutter 앱에서도 같은 값을 다시 가리는 방어적 redaction을 적용했다.
- V3 안내 화면에 기본 접힘형 `모비가 실제 데이터를 확인했어` 카드와 `검증 과정 보기` 타임라인을 추가했다.
- 운영 VM 백엔드와 Flutter web 정적 파일을 배포했다.

## 운영 주소

- 사용자 화면: `https://mobi.35.232.72.197.nip.io/app/#/v3-guidance`
- Health: `https://mobi.35.232.72.197.nip.io/health`

## 운영 VM 정확한 위치

| 항목 | 값 |
| --- | --- |
| GCP project | `gen-lang-client-0309873247` |
| Compute Engine instance | `instance-20260330-105638` |
| zone | `us-central1-b` |
| external IP | `35.232.72.197` |
| SSH account | 현재 `gcloud` 로그인 계정 |
| application owner | `sst70` |
| source root | `/home/sst70/mobi-deploy/mobi-smart-transport-ai` |
| backend service | `mobi-backend.service` |
| backend bind | `127.0.0.1:8000` |
| reverse proxy | Caddy |
| Caddy config | `/etc/caddy/Caddyfile` |
| Flutter static root | `/home/sst70/mobi-deploy/mobi-smart-transport-ai/apps/passenger_app/build/web` |

이 VM은 nginx가 아니라 Caddy를 사용한다. FastAPI가 `/app` 정적 파일도 제공하며 Caddy가 외부 HTTPS 요청을 `127.0.0.1:8000`으로 전달한다.

## 주요 구현 파일

- `backend/api/app/schemas/v3.py`
- `backend/api/app/services/v3_agent_trace.py`
- `backend/api/app/services/v3_agent_tools.py`
- `backend/api/app/api/routes/v3_agent.py`
- `backend/api/tests/test_v3_agent_trace.py`
- `apps/passenger_app/lib/src/models/v3_guidance_models.dart`
- `apps/passenger_app/lib/src/pages/v3_guidance_page.dart`
- `apps/passenger_app/test/widget_test.dart`

## 검증 결과

- Python compile: 통과
- FastAPI tests: `160 passed`
- public data client tests: `30 OK`
- Flutter analyze: `No issues found`
- Flutter tests: `9 passed`
- Caddy validation: `Valid configuration`
- 운영 서비스: `mobi-backend.service=active`, `caddy=active`
- 외부 API smoke: `/health=ok`, Agent Trace `14`단계, 첫 단계 `NORMALIZE_UTTERANCE`, 마지막 단계 `FINAL_RESPONSE`
- 외부 API redaction smoke: 비밀 키 표식 미노출
- 브라우저 smoke: 접힌 trace 카드와 펼친 타임라인 표시 확인

## 배포 백업

- Backend 배포 전: `/home/sst70/mobi-deploy/backups/mobi-agent-trace-before-20260602T012516Z`
- Web 배포 전: `/home/sst70/mobi-deploy/backups/mobi-agent-trace-web-before-20260602T013107Z`
- 잘못된 base href 빌드 보존: `/home/sst70/mobi-deploy/backups/mobi-agent-trace-web-misbased-20260602T013631Z`

Flutter web은 반드시 `/app/` 기준으로 빌드한다.

```bash
flutter build web --release \
  --base-href /app/ \
  --dart-define=MOBI_API_BASE_URL=https://mobi.35.232.72.197.nip.io \
  --dart-define=MOBI_WEB_DEMO_ORIGIN_ENABLED=true
```

## Claude Code 인수인계 프롬프트

아래 프롬프트를 그대로 전달하면 된다.

```text
MOBI V3 운영 프로젝트를 수정해야 한다. 새 VM이나 비슷한 이름의 프로젝트를 추측하지 말고 아래의 정확한 리소스만 사용해라.

GCP project: gen-lang-client-0309873247
Compute Engine instance: instance-20260330-105638
zone: us-central1-b
external IP: 35.232.72.197
production URL: https://mobi.35.232.72.197.nip.io/app/#/v3-guidance
production source root: /home/sst70/mobi-deploy/mobi-smart-transport-ai
application owner: sst70
backend systemd service: mobi-backend.service
backend bind: 127.0.0.1:8000
reverse proxy: Caddy
Caddy config: /etc/caddy/Caddyfile
Flutter static root: /home/sst70/mobi-deploy/mobi-smart-transport-ai/apps/passenger_app/build/web

접속은 다음 패턴으로 시작해라.

gcloud compute ssh instance-20260330-105638 \
  --project='gen-lang-client-0309873247' \
  --zone='us-central1-b' \
  --quiet

중요:
1. 이 서버는 nginx가 아니라 Caddy를 사용한다. nginx 설정이나 nginx 서비스를 찾느라 시간을 쓰지 마라.
2. 코드를 수정하기 전에 /home/sst70/mobi-deploy/backups 아래에 UTC timestamp 백업을 만들어라.
3. 소스 파일은 sst70 소유권을 유지해라. 테스트와 빌드는 가능하면 sudo -u sst70 bash -lc '...' 형태로 실행해라.
4. .env는 키 이름 존재 여부만 확인하고 값은 출력하거나 복사하지 마라.
5. 백엔드 수정 후 다음을 실행해라.
   env PYTHONPATH=backend/api:services/public_data:. .venv/bin/python -m pytest backend/api/tests -q -p no:cacheprovider
   env PYTHONPATH=backend/api:services/public_data:. .venv/bin/python -m unittest discover -s services/public_data/tests -q
   .venv/bin/python -m compileall -q backend/api/app services/public_data/public_data_client
6. 백엔드 반영은 mobi-backend.service만 재시작하고 systemctl is-active로 상태를 확인해라.
7. Flutter web 배포 시 반드시 --base-href /app/를 넣어라. 누락하면 브라우저가 /flutter_bootstrap.js를 읽어서 빈 화면이 된다.
8. Flutter 정적 파일 교체 후 /app/ HTML의 <base href="/app/">를 확인해라.
9. Caddyfile을 바꾸지 않았다면 reload하지 말고 caddy validate --config /etc/caddy/Caddyfile만 실행해라.
10. 검증은 localhost health, 공개 health, 공개 /agent/converse smoke, 실제 브라우저 화면 순서로 진행해라.

현재 핵심 구현은 FastAPI 내부 tool layer와 agent state machine이다. Gemini function calling을 한꺼번에 붙이지 마라. 먼저 backend/api/app/services/v3_agent_tools.py와 backend/api/app/services/v3_agent_trace.py를 읽고 기존 도구 경계를 유지해라.

Agent Trace 요구사항:
- API 응답의 traceId와 trace를 유지해라.
- raw exception, API 키, authorization, token, password, secret, 전체 URL, 정밀 GPS, raw 외부 응답을 trace에 넣지 마라.
- Flutter 화면은 기본 접힘 상태를 유지해라.
- backend redaction과 Flutter display redaction을 둘 다 유지해라.
```
