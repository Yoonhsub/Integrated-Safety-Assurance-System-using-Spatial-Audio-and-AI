"""V2 섹션 10 — AI Vision mock pipeline 검증 테스트 패키지.

본 디렉토리는 V2 섹션 8 산출물(mock_inference_pipeline + Safety Event fixture 4건) +
V2 섹션 9 산출물(class_taxonomy.json v0.3.0)의 정합성을 시나리오 단위로 검증하는
unit test를 둔다.

실행 환경:

- pytest 권장: ``pytest ai_vision/pipelines/tests/``
- stdlib 대체: ``python -m unittest discover ai_vision/pipelines/tests``

환경 제약 (V1·V2 일관):

- ``pydantic`` / ``httpx`` / ``jsonschema`` 미설치 시 본 테스트는 stdlib만으로 실행됨.
  Pydantic 인스턴스 검증은 가용 환경에서만 자동 활성화(@unittest.skipUnless).

본 테스트는 외부 네트워크 호출을 일절 하지 않는다 — 모든 검증은 ZIP 안의 정적 파일만 사용.
"""
