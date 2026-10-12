# Firebase 통합 웹 배포 준비

대상 프로젝트: `mobi-smart-transport`. Flutter Web은 Firebase Hosting,
FastAPI는 같은 프로젝트의 Cloud Run에서 실행한다. VM은 필요하지 않다.
현재 목표는 사전 등록 계정의 REST 연동을 확인할 통합 검증 배포다.
브라우저 스트리밍과 실제 승차 안전 안내까지 완료된 운영 서비스는 아니다.

## 배포 구성

- Hosting 사이트 `mobi-smart-transport`: `/` 진입 화면, `/passenger/`, `/driver/`.
- Driver Web 등록 시 연결된 별도 사이트 `mobi-smart-transport-6e401`은 이번 배포 대상이 아니다.
  Web 앱 등록과 Hosting 사이트는 별개다. 두 앱은 각자의 Firebase appId를 유지한다.
- 두 앱의 `MOBI_API_BASE_URL`은 배포 후 확인한 Cloud Run HTTPS origin이다.
  Hosting rewrite로 API 경로를 바꾸지 않는다. 기존 API contract를 유지한다.
- Cloud Run CORS는 두 Hosting origin만 허용한다. 새 도메인을 쓰면 CORS와 Auth 허용 도메인을 함께 검토한다.
- Cloud Run은 Firebase ID token을 애플리케이션에서 검증하므로 HTTP 요청은 컨테이너까지 도달해야 한다.
  Cloud Run IAM의 `allow-unauthenticated`는 Google IAM 호출 토큰 요구를 해제하는 설정이다.
  앱의 Firebase 인증/역할/소유권 검사를 제거하는 설정이 아니다. 이 공개 진입 설정은 배포 승인 대상이다.

## 배포 전 필수 준비

1. 프로젝트의 Cloud Billing 연결/Blaze와 예산 알림을 소유자가 확인한다. 예산 알림은 지출 상한이 아니다.
2. Realtime Database를 적절한 지역에 생성하고 **잠금 모드**로 시작한다.
   테스트 모드 공개 읽기/쓰기를 켜지 않는다. Console이 제공한 정확한 URL을 사용한다.
3. Cloud Run 전용 서비스 계정을 준비한다. Auth의 `firebaseauth.users.get` 권한과
   해당 RTDB 접근 권한이 필요하다. Firebase Authentication Viewer 및
   Firebase Realtime Database Admin 역할을 검토하되, 프로젝트 Owner/Editor는 부여하지 않는다.
   실제 서비스 계정/IAM 부여는 소유자 승인 후 수행한다. RTDB Admin은 DB 전체 접근 권한이므로
   이 프로젝트의 배포 API 전용 계정에만 부여한다. Admin SDK는 클라이언트 RTDB rules를 우회한다.
4. Firebase 계정에 서버에서 `mobi_role`을 설정한다. 기사는 별도 `mobi_driver_id`와
   `/drivers/{driverId}`의 routeId/busNo 담당 관계를 등록한다. 임의 UID=기사 ID 매핑은 금지한다.
5. Firebase CLI 로그인과 Google Cloud CLI 설치/로그인을 확인한다. 브라우저 로그인과 CLI 로그인은 별개다.
6. Cloud Run, Cloud Build, Artifact Registry API 및 이미지 저장소를 승인 후 준비한다.
   아래 예시는 `asia-northeast3`, 저장소 `mobi`, 서비스 `mobi-api`를 제안하며 아직 생성되지 않았다.

## 로컬 배포 파일 준비

프로젝트 루트(`mobi-smart-transport-ai`)에서 PowerShell로 실행한다.
외부 출력 폴더는 새 경로여야 한다. 스크립트는 기존 경로를 덮어쓰거나 배포하지 않는다.

```powershell
$python = (Resolve-Path 'backend/api/.venv/Scripts/python.exe').Path
$stage = 'C:\mobi-ai\deploy\release-001' # 새 경로
& $python -B scripts/prepare_firebase_deployment.py backend --output "$stage\backend"
```

백엔드 빌드 context는 app Python, public_data client/example JSON, requirements와 Dockerfile만 복사한다.
로컬 `.env`, Admin 키, 데이터셋, 모델 weight, Flutter 캐시는 업로드 대상에 포함하지 않는다.
실행 Python은 3.13, 프로세스는 non-root, Uvicorn worker는 1개, 포트는 Cloud Run의 `PORT`를 따른다.
YOLO 모델은 API 컨테이너에 설치하지 않는다. 현재 AI Vision ingestion은 별도 인증된 수집기를 필요로 한다.

`infrastructure/cloud_run/runtime.example.yaml`을 저장소 밖에 복사하고 DB URL을 채운다.
Cloud Run은 `FIREBASE_USE_ADC=true`로 서비스 계정의 Application Default Credentials를 사용한다.
서비스 계정 JSON 키를 앱·이미지에 넣지 않는다. staging/production에서 Firebase 저장소 초기화가
실패하면 503/시작 실패로 차단하며 메모리 Mock에 정상 저장한 것처럼 응답하지 않는다.
SDK 초기화 성공은 실제 DB 접근 권한까지 입증하지 않으므로 배포 후 인증된 저장·조회 검증이 필요하다.

## 승인 후 실행할 클라우드 명령

이 명령들은 클라우드 리소스를 생성하고 비용이 발생할 수 있다. 준비 스크립트는 실행하지 않는다.
프로젝트·지역·서비스 계정·DB URL·공개 진입 정책을 확정하고 실행한다.

```powershell
$project = 'mobi-smart-transport'
$region = 'asia-northeast3'
$service = 'mobi-api'
$runtimeAccount = '<approved-runtime-service-account>@mobi-smart-transport.iam.gserviceaccount.com'
$image = "$region-docker.pkg.dev/$project/mobi/mobi-api:release-001"
gcloud builds submit "$stage\backend" --project $project --tag $image
gcloud run deploy $service --project $project --region $region --image $image `
  --service-account $runtimeAccount --env-vars-file "$stage\runtime.yaml" `
  --port 8080 --cpu 1 --memory 512Mi --concurrency 1 --min-instances 0 --max-instances 1 `
  --allow-unauthenticated
$apiUrl = gcloud run services describe $service --project $project --region $region --format='value(status.url)'
```

단일 인스턴스/낮은 동시성은 현재 메모리 세션 및 저장 경쟁 위험을 줄일 뿐,
재시작·새 revision·배포 중 revision 병존 시 세션 유실/요청 경쟁을 해결하지 않는다.
고가용 운영 전에는 세션 소유권의 영속 저장, 재연결, RTDB transaction 등의 별도 작업이 필요하다.

앱별 `infrastructure/firebase/web-defines.example.json` 복사본에 Console의 공개 설정 5개를 채운다.
API key는 Web 앱의 공개 설정이고 Admin private key가 아니다. 로그인 비밀번호/토큰을 넣지 않는다.

```powershell
& $python -B scripts/prepare_firebase_deployment.py web --output "$stage\hosting" `
  --passenger-defines "$stage\passenger-defines.json" `
  --driver-defines "$stage\driver-defines.json" --api-url $apiUrl
Push-Location "$stage\hosting"
firebase deploy --only hosting --project mobi-smart-transport --config firebase.json
Pop-Location
```

앱 소스 복사본에서 lockfile을 강제해 의존성을 설치하고 release build한다.
Hosting `public`은 `web`만 지정한다. 임시 소스/설정 파일을 publish하지 않는다.
Hosting config에는 database rules가 없으며 `--only hosting`으로만 배포한다.
현재 배포한 RTDB 규칙 변경은 별도 검토/승인 사항이다.

## 배포 검증과 완료 기준

- 두 앱의 base href `/passenger/`, `/driver/`와 새로고침/정적 asset 로딩을 확인한다.
- 실제 사전 등록 승객/기사 로그인, 미인증 401, 역할 부족 403, 인증 장애 503을 확인한다.
- 로그인된 승객 요청의 RTDB 기록과 재조회, 배정된 기사의 조회/상태 변경을 확인한다.
  현재 자동 기사 배정 경로는 미완성이므로 요청 생성만으로 기사에게 보인다고 보장하지 않는다.
- Cloud Run 서비스 계정으로 Auth user 조회/RTDB 접근을 실제 검증한다.
- WebSocket 인증 ticket 흐름, 관리자 전용 guidance/event, AI/BLE 수집기 인증,
  실시간 공공 API 키, FCM 수신, 실제 승차 허용은 미완료 범위다. 관리자 토큰을 앱에 넣지 않는다.
- 예시 runtime은 PUBLIC_DATA_USE_MOCK=true/FCM 비활성인 검증용 설정이다.
  공개 웹 사이트가 열리는 것만으로 실시간 데이터 통합이나 안전 안내 완료를 의미하지 않는다.
- 실제 Cloud Run URL이 없을 때 `.invalid` origin으로 만든 로컬 빌드는 컴파일 검증 전용이다.
  이를 Hosting에 배포하지 않는다. 실제 URL로 새 출력 경로에 재빌드한다.

## 참고

- https://firebase.google.com/docs/hosting/cloud-run
- https://docs.cloud.google.com/run/docs/authenticating/end-users
- https://docs.cloud.google.com/run/docs/securing/service-identity
- https://docs.cloud.google.com/run/docs/container-contract
