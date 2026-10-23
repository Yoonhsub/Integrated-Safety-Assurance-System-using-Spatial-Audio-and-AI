# MOBI 하드웨어 테스트 앱

비콘 2개와 WT901 BLE 센서, 골전도 이어폰을 함께 확인하는 독립 Android 앱입니다.
설치와 실행은 [실행방법.md](실행방법.md)를 참고하세요.

저장소 루트의 `.github`, `mobi-smart-transport-ai`와 같은 위치에 있습니다.
`../mobi-smart-transport-ai/packages/mobile_sensors`를 참조하므로 저장소 전체를 받아야 합니다.
기존 바탕화면 개인 테스트 앱은 그대로 보존했습니다.

- 비콘 A: `C3:00:00:5C:B9:47`, B: `C3:00:00:5C:B9:48`
- WT901BLE68: `F1:35:40:62:CD:43`
- 15초/60초 연속 스캔, RSSI 및 수신 횟수 표시
- WT901 각도 수신과 비콘 동시 스캔
- 수동 Z축 기준에 따른 좌우 소리 및 RSSI에 따른 220~1400ms 소리 간격

RSSI는 정확한 거리나 방향을 뜻하지 않습니다. 방향음은 수동 기준에 대한 센서 회전으로 계산하며 HRTF 기능은 아닙니다.
Passenger 앱이나 서버와의 통합은 별도 작업입니다. 빌드 결과, 로컬 SDK 경로, 키 파일은 커밋하지 않습니다.

프로토콜 참고: https://github.com/WITMOTION/WitBluetooth_BWT901BLE5_0

## 검증 기록

저장소 내 새 위치에서 flutter pub get, flutter analyze, flutter test(13개), Android arm64 debug APK 빌드를 통과했습니다. 비콘/센서 동시 수신 및 골전도 소리는 이전 개인 앱에서 사용자 확인을 받았습니다.
