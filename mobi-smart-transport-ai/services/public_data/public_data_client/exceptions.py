"""공공데이터 클라이언트 영역 전용 예외.

이 모듈은 services/public_data 내부에서만 발생하는 오류를 계층적으로 표현한다.
backend/api나 Flutter 앱은 이 예외 타입을 직접 import하지 않으며,
김도성 모듈은 외부에는 ``NormalizedBusArrivalsResponse`` 표준 출력 또는
명시된 예외만 노출한다.

분류:
- ``PublicDataError`` (기반 클래스)
    - ``PublicDataServiceKeyMissingError``
        : ``PUBLIC_DATA_API_KEY`` 누락 또는 빈 값.
    - ``PublicDataNetworkError``
        : 네트워크/타임아웃/HTTP 실패 등 호출 자체가 실패한 경우.
    - ``PublicDataEmptyResponseError``
        : 호출 자체는 성공이지만 결과가 비어 있어 normalize 불가한 경우.

TODO(김도성, 섹션 6):
    실제 API 응답에서 발견되는 부분 실패 케이스(일부 필드 누락, enum 외 값,
    원본 응답에 ``resultCode != "00"``)를 표현하는 세부 예외를 추가한다.
"""

from __future__ import annotations


class PublicDataError(Exception):
    """공공데이터 클라이언트 영역의 모든 예외의 기반 클래스."""


class PublicDataServiceKeyMissingError(PublicDataError):
    """``PUBLIC_DATA_API_KEY`` 환경변수가 설정되어 있지 않거나 빈 값일 때 발생.

    해결 방법:
    - ``PUBLIC_DATA_USE_MOCK=true`` 로 두면 클라이언트가 호출되지 않으므로
      이 예외도 발생하지 않는다. (4월 MVP 기본 권장 경로)
    - 실제 키를 사용하고 싶다면 ``.env`` 또는 OS 환경변수에 발급받은 서비스키를
      설정한다. 단 실제 키는 git 저장소에 커밋하지 않는다.
    """


class PublicDataNetworkError(PublicDataError):
    """공공데이터 API 호출 자체가 네트워크/타임아웃/HTTP 오류로 실패한 경우.

    원인 예시:
    - DNS 실패, 라우팅 문제, 방화벽
    - 타임아웃
    - 비-2xx HTTP 상태 코드
    """


class PublicDataEmptyResponseError(PublicDataError):
    """호출 자체는 성공했으나 결과가 비어 있어 normalize 불가한 경우.

    원인 예시:
    - 정류장에 현재 운행 중인 버스가 없는 시간대
    - 잘못된 ``stopId`` 또는 도시코드
    - 일부 공공데이터 API가 결과 0건을 빈 ``items`` 또는 빈 문자열로 반환

    이 경우 호출자는 빈 ``arrivals`` 배열을 가진 정상 응답을 만들지,
    오류로 처리할지를 정책에 따라 결정한다. 4월 mock 단계에서는
    빈 ``arrivals`` 응답이 더 안전한 기본 동작이다.
    """
