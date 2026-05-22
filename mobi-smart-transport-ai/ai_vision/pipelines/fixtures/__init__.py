"""V2 섹션 8 산출물 — Mock AI Inference Pipeline fixtures.

본 디렉토리는 김도성 V2 에이전트가 V2 섹션 8 (Mock AI Inference Pipeline)에서
생성한 Safety Event mock fixture를 담는다. 정식 등록 schema는 V2 섹션 11 또는
2학기 단계 2에서 안준환 협의 후 ``packages/shared_contracts/api/``로 이동 예정.

본 fixture는 ``ai_vision/pipelines/README.md`` §3.4 (V2 섹션 7) Safety Event
Schema 후보와 정합한다. 후속 통합 단계(2학기 단계 3)에서 윤현섭 Flutter UI /
심현석 backend가 본 fixture를 mock 입력으로 사용해 통합 흐름을 검증한다.

파일:

- ``mock_safety_events.json`` — Safety Event 샘플 4건
  - (a) ``info``  + ``bus_stop_recognized``     + 단일 detection (bus_stop)
  - (b) ``warn``  + ``approaching_bus``          + 다중 detection (bus, bus_door, bus_stop)
  - (c) ``danger`` + ``off_sidewalk``            + 다중 detection (roadway, sidewalk)
  - (d) ``danger`` + ``tactile_paving_lost``     + 빈 detections (사건 자체가 "사라짐")
"""
