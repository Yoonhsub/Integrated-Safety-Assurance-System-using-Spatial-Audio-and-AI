# V3 Demo Script

## 최종 발표 시연 순서

1. **"자비스, 나 사창사거리 가야 하는데 몇 번 버스 타야 돼?"**
   - FIND_ROUTE intent 감지
   - 502번 / 충북대중문 정류장 추천
   - ROUTE_RECOMMENDED 상태

2. **"자비스, 그 버스 언제 와?"**
   - GET_BUS_ARRIVAL intent
   - 6분 뒤 / 25분 뒤 도착 정보

3. **"응, 6분 뒤 오는 걸로 안내해줘."**
   - SELECT_ARRIVAL intent
   - ROUTE_SELECTED 상태, targetBusId 저장

4. **[정류장 범위 진입] 버튼**
   - ARRIVED_AT_STOP mock
   - geofenceArmed = true
   - WAITING_FOR_BUS 상태

5. **[정류장 범위 이탈] 버튼**
   - LEFT_WAITING_AREA
   - WARNING 경고 발화

6. **[BUS_1 접근] 버튼**
   - BUS_1(511번) near + BUS_2(502번) mid
   - WRONG_BUS_NEAR 판정
   - 경고 음성 재생

7. **"자비스, 지금 앞에 온 버스 타도 돼?"**
   - ASK_CAN_BOARD_CURRENT_BUS
   - WRONG_BUS_NEAR → "아니요" 응답

8. **[BUS_2 접근] 버튼**
   - BUS_2(502번) near
   - TARGET_BUS_NEAR 판정
   - 빠른 비프음/진동 큐

9. **"자비스, 나 못 탔어."**
   - REPORT_MISSED_BUS
   - MISSED_BUS → REPLAN_NEXT_BUS → WAITING_FOR_BUS
   - 다음 버스 안내

## Demo 준비 체크리스트

- [ ] backend 서버 실행: `uvicorn app.main:app --reload`
- [ ] Flutter 앱 빌드 및 실행
- [ ] smoke_v3_guidance.py 사전 실행 확인
- [ ] GEMINI_API_KEY 없어도 rule fallback 동작 확인
