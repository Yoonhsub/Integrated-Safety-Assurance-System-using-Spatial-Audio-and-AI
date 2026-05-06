# Firebase Infrastructure - 심현석 담당 영역

Firebase Realtime Database, FCM, 보안 규칙 초안 영역입니다.

## 4월 구현 범위

- RTDB 논리 스키마 확정
- users/drivers/busStops/geofences/busArrivals/rideRequests 경로 설계
- FCM token 저장 경로 정의
- 최소 개발용 rules 초안 작성

## 주의

공공데이터 API 직접 호출 구현은 하지 않습니다. `busArrivals`에는 김도성 public_data 서비스의 표준화 결과가 저장되거나 백엔드 게이트웨이를 통해 전달됩니다.
