# docs/rw/ARCHITECTURE.md

> MOBI 프로젝트의 전체 시스템 아키텍처 문서이다.  
> 이 문서는 요구사항명세서, 4월 개인별 구현범위 수정안, 공통 프로젝트 스캐폴딩을 기준으로 작성되었다.  
> 목적은 세부 기능을 완성하는 것이 아니라, 팀원들이 생성형 AI를 병렬 활용해도 **역할 경계·모듈 경계·데이터 흐름·확장 지점**이 흐트러지지 않도록 하는 것이다.

---

## 1. 프로젝트 개요

MOBI 프로젝트는 시각장애인과 노약자를 위한 스마트 교통 AI 에이전트 시스템이다.

핵심 목표는 다음과 같다.

```txt
- 음성 중심 사용자 인터페이스 제공
- 정류장 주변 안전 상태 안내
- 지오펜싱 기반 위험구역 진입/이탈 판별
- 실시간 버스 도착 정보 및 저상버스 정보 제공
- 승객-기사 간 탑승 요청 매칭
- BLE/RSSI 기반 정밀 탑승 유도 기반 마련
- 2학기 AI 비전 기능 확장을 위한 데이터/모델 준비
- 향후 헤드트래킹 및 공간음향 기능 확장 가능 구조 확보
```

4월 구현범위는 완성형 서비스가 아니라 **MVP 뼈대와 핵심 계약 확정**에 초점을 둔다.

---

## 2. 전체 저장소 구조

```txt
mobi-smart-transport-ai/
├── apps/
│   ├── passenger_app/
│   └── driver_app/
├── backend/
│   └── api/
├── services/
│   └── public_data/
├── packages/
│   ├── mobile_sensors/
│   └── shared_contracts/
├── ai_vision/
├── future_modules/
│   ├── head_tracking/
│   └── spatial_audio/
├── infrastructure/
│   └── firebase/
├── scripts/
├── docs/
├── .github/
└── *.md
```

---

## 3. 모듈별 책임

## 3.1 apps/passenger_app

담당자: 윤현섭

사용자용 Flutter 앱 영역이다.

주요 책임:

```txt
- 사용자 앱 메인 화면
- 초대형 버튼 기반 접근성 UI
- STT 음성 입력 화면
- TTS 음성 안내
- 버스 도착 정보 렌더링
- 안전 상태 경고 UI
- 탑승 요청 UI
- mock/API 응답 소비
```

직접 담당하지 않는 것:

```txt
- FastAPI 내부 로직
- Firebase DB 스키마 확정
- 공공데이터 API 직접 호출
- BLE/RSSI 센서 직접 구현
- AI 비전 모델 학습
```

---

## 3.2 apps/driver_app

담당자: 윤현섭

기사용 Flutter 앱 영역이다.

주요 책임:

```txt
- 기사용 앱 기본 화면
- 승객 탑승 요청 목록 UI
- 승객 대기 알림 카드
- 요청 상태 표시
- 향후 FCM 알림 수신 UI
```

주의:

```txt
rideRequests 데이터 구조와 status enum은 심현석 백엔드/Firebase 파트의 선행 계약에 의존한다.
```

---

## 3.3 backend/api

담당자: 심현석

FastAPI 기반 백엔드 영역이다.

주요 책임:

```txt
- FastAPI 앱 구조
- Firebase Admin SDK 연결
- 지오펜싱 판별 API
- 사용자 위치 상태 판별
- FCM 알림 전송 인터페이스
- rideRequests 기사-승객 매칭 파이프라인
- 김도성 공공데이터 표준 JSON 수신 인터페이스
```

직접 담당하지 않는 것:

```txt
- 공공데이터 API 직접 호출 구현
- Flutter 화면 구현
- BLE/RSSI 센서 구현
- AI 비전 모델 리서치/데이터 수집
```

---

## 3.4 services/public_data

담당자: 김도성

공공데이터 API 연동 및 표준화 영역이다.

주요 책임:

```txt
- 공공데이터 API 조사
- 정류장별 버스 도착 정보 조회 모듈
- 실시간 버스 위치 정보 가능성 조사
- 저상버스 여부 필터링
- 혼잡도 정보 표준화
- 표준 응답 JSON 작성
- mock 응답 JSON 작성
```

직접 담당하지 않는 것:

```txt
- FastAPI 라우트 직접 구현
- Firebase 저장 구조 변경
- Flutter UI 직접 수정
- BLE/RSSI 테스트 계획
- 공간음향 방향 테스트 계획
```

---

## 3.5 packages/mobile_sensors

담당자: 안준환

센서/BLE/RSSI 모듈 영역이다.

주요 책임:

```txt
- BLE 비콘 스캔 인터페이스
- 특정 비콘 ID 필터링
- RSSI 기반 거리 추정
- 신호 상태값 분류
- 스마트폰 방향 센서 인터페이스
- 센서 데이터 모델 정의
```

4월 구현 제외:

```txt
- 외부 헤드트래킹 센서 통신
- 헤드트래킹 기반 공간음향
- 비콘 거리 테스트 계획 문서화
- 공간음향 방향 테스트 계획 문서화
```

---

## 3.6 packages/shared_contracts

담당자: 공통 아키텍처 / 관련 팀원 협의

공통 API/데이터 계약 영역이다.

주요 책임:

```txt
- geofence request/response schema
- bus arrival standard schema
- ride request schema
- common enum
- error response schema
```

주의:

```txt
shared_contracts는 여러 팀원이 참조하는 공통 계약 영역이다.
임의 수정 시 반드시 docs/rw/충돌 이슈.md에 기록하고 관련 팀원과 협의해야 한다.
```

---

## 3.7 ai_vision

담당자: 김도성

2학기 AI 비전 기능 준비 영역이다.

주요 책임:

```txt
- 버스/정류장/장애물/위험구역 이미지 데이터 수집 계획
- 탐지 클래스 정의
- 모바일 경량 AI 모델 리서치
- 2학기 AI 비전 파이프라인 초안
```

4월 목표:

```txt
4월에는 실제 모델 학습/추론 코드나 Flutter/백엔드 실시간 통합을 구현하지 않는다. 4월 범위는 데이터 수집 계획, 라벨링 기준, 모델 후보 리서치, 2학기 파이프라인 초안 작성이다.
```

---

## 3.8 future_modules/head_tracking

담당자: 향후 확정

헤드트래킹 확장 프레임이다.

현재 상태:

```txt
4월 구현 대상 아님.
헤드트래킹 센서 구매 전까지 실제 구현 금지.
```

목적:

```txt
향후 외부 센서를 구매하면 해당 모듈에 통신/데이터 모델/보정 로직을 추가한다.
```

---

## 3.9 future_modules/spatial_audio

담당자: 향후 안준환 중심 가능

공간음향 확장 프레임이다.

현재 상태:

```txt
4월 구현 대상 아님.
헤드트래킹과 BLE/RSSI 입력 구조가 안정화된 뒤 구현.
```

목적:

```txt
버스 출입문 방향을 공간음향으로 안내하는 기능을 향후 구현한다.
```

---

## 3.10 infrastructure/firebase

담당자: 심현석 중심 / 공통 검토 필요

Firebase 설정과 스키마 문서 영역이다.

주요 책임:

```txt
- Firebase Realtime Database schema
- Firebase rules 초안
- FCM 설정 메모
- Firebase Admin SDK 연결 문서
```

---

## 4. 전체 데이터 흐름

## 4.1 사용자 안전 경고 흐름

```txt
사용자 앱
→ 현재 GPS 좌표 수집
→ backend/api /geofence/check 요청
→ FastAPI가 Firebase geofences 조회
→ 안전/경고/위험 상태 판별
→ 필요 시 FCM 또는 앱 응답으로 경고 전달
→ 사용자 앱이 TTS/화면/진동 안내
```

관련 모듈:

```txt
apps/passenger_app
backend/api
infrastructure/firebase
packages/shared_contracts
```

---

## 4.2 버스 도착 정보 흐름

```txt
services/public_data
→ 공공데이터 API 호출
→ 도착 정보/저상버스/혼잡도 표준화
→ 표준 JSON/mock 생성
→ backend/api 또는 passenger_app이 표준 JSON 소비
→ 사용자 앱에서 버스 정보 렌더링
```

관련 모듈:

```txt
services/public_data
backend/api
apps/passenger_app
packages/shared_contracts
```

주의:

```txt
공공데이터 API 직접 연동은 김도성 담당.
심현석은 결과를 받을 인터페이스를 준비한다.
윤현섭은 표준 JSON을 렌더링한다.
```

---

## 4.3 탑승 요청 매칭 흐름

```txt
사용자 앱
→ 탑승 요청 생성
→ backend/api /ride-requests 요청
→ Firebase /rideRequests 저장
→ FCM으로 기사 앱 알림
→ 기사 앱에서 요청 목록 표시
→ 기사 앱 또는 백엔드가 상태 변경
→ 사용자 앱이 상태 변화 확인
```

관련 모듈:

```txt
apps/passenger_app
apps/driver_app
backend/api
infrastructure/firebase
packages/shared_contracts
```

---

## 4.4 BLE/RSSI 탑승 유도 기반 흐름

```txt
mobile_sensors
→ BLE 비콘 스캔
→ RSSI 값 수집
→ 거리 추정
→ 신호 상태값 분류
→ 향후 사용자 앱/공간음향 모듈에서 활용
```

관련 모듈:

```txt
packages/mobile_sensors
future_modules/spatial_audio
apps/passenger_app
```

4월에는 실제 앱 통합보다 모듈 프레임과 기본 로직이 우선이다.

---

## 4.5 AI 비전 향후 흐름

```txt
카메라 입력
→ 객체 탐지 모델
→ 버스/정류장/차도/장애물/버스 문 탐지
→ 위험 요소 판단
→ 사용자 앱 음성 안내 또는 백엔드 이벤트 연동
```

관련 모듈:

```txt
ai_vision
apps/passenger_app
backend/api
```

4월에는 데이터 수집 계획과 모델 리서치만 수행한다.

---

## 5. 4월 MVP 아키텍처 범위

4월 말까지 목표로 하는 것은 다음이다.

```txt
- Flutter 사용자 앱/기사 앱 기본 shell
- STT/TTS 기본 동작 또는 인터페이스
- 접근성 UI 기본 적용
- FastAPI/Firebase 기본 구조
- 지오펜싱 API 계약 및 skeleton
- FCM 알림 구조 skeleton
- rideRequests 데이터 구조 skeleton
- 공공데이터 API 조사 및 표준 mock JSON
- 저상버스/혼잡도 표준화 기준
- BLE/RSSI 모듈 skeleton
- AI 비전 데이터/모델 준비 문서
```

4월 범위가 아닌 것:

```txt
- 실제 AI 모델 학습/추론 코드 및 Flutter/백엔드 실시간 통합
- 헤드트래킹 실제 구현
- 공간음향 실제 구현
- 실외 필드 테스트 완성
- 상용 수준의 보안/인증
```

---

## 6. 선행작업 의존성 요약

자세한 내용은 `docs/rw/선행작업의존성 정리.md`를 따른다.

강한 의존성:

```txt
김도성 섹션 2, 3
→ 윤현섭 섹션 6, 7

심현석 섹션 4, 5
→ 윤현섭 섹션 6, 7

김도성 섹션 6, 7
→ 심현석 섹션 10, 11

심현석 섹션 8, 9
→ 윤현섭 섹션 8, 9
```

주의:

```txt
이 의존성은 후행 에이전트가 이전 섹션을 건너뛰어도 된다는 뜻이 아니다.
각 에이전트는 자기 섹션을 반드시 1부터 순차적으로 수행한다.
```

---

## 7. 확장 전략

## 7.1 헤드트래킹

```txt
4월: future_modules/head_tracking 프레임만 유지
이후: 센서 구매 후 통신/데이터 모델/보정 로직 구현
```

## 7.2 공간음향

```txt
4월: future_modules/spatial_audio 프레임만 유지
이후: BLE/RSSI, 방향 센서, 헤드트래킹을 통합한 위치 안내 구현
```

## 7.3 AI 비전

```txt
4월: 실제 모델 학습/추론 코드와 Flutter/백엔드 실시간 통합은 구현하지 않고, 데이터 수집 계획·라벨링 기준·모델 후보 리서치·2학기 파이프라인 초안만 작성
2학기: 모바일 경량 모델 PoC, Flutter/백엔드 통합
```

---

## 8. 아키텍처 변경 절차

아키텍처를 변경해야 한다면 다음 절차를 따른다.

```txt
1. 변경 필요성 확인
2. 영향받는 팀원 식별
3. docs/rw/충돌 이슈.md 기록
4. 관련 팀원과 협의
5. docs/rw/ARCHITECTURE.md 수정
6. docs/rw/API_CONTRACTS.md 또는 docs/rw/DATA_SCHEMA.md 수정 필요 여부 확인
7. docs/rw/공통 진행사항.md에 기록
8. PR로 병합
```

공통 계약 영역을 임의로 변경해서는 안 된다.

---

## 9. 최종 원칙

```txt
앱은 UI를 책임진다.
백엔드는 판단과 실시간 데이터 흐름을 책임진다.
공공데이터 모듈은 외부 API와 표준화를 책임진다.
센서 패키지는 BLE/RSSI/방향 센서 기반을 책임진다.
공통 계약은 모두가 지킨다.
향후 기능은 프레임만 두고 4월 구현 범위와 섞지 않는다.
```
