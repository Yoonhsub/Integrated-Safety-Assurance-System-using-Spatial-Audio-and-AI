"""BusArrivalsService V2 테스트 패키지 (섹션 4 산출물).

본 디렉토리는 V2 섹션 3에서 정밀화된 ``_normalize_arrivals`` (TAGO 키 셋 분기 +
응답 timestamp 우선 사용 + 빈 raw_items early return)와 ``BusArrivalsService``
공개 API(`get_arrivals(stop_id)`)의 6 시나리오 회귀 테스트를 둔다.

실행 환경:
- pytest 권장: ``pytest services/public_data/tests/``
- stdlib 대체: ``python -m unittest discover services/public_data/tests``

환경 제약 (4월/V2 일관):
- ``pydantic`` / ``httpx`` 미설치 시 일부 인스턴스 테스트는 NOT_RUN으로 skip.
- 핵심 정규화 로직(빈 list early return, TAGO 키 셋 분기, banker's rounding,
  안전 기본값 흡수)은 stub 시뮬레이션으로 unittest 환경에서도 실행 가능.
"""
