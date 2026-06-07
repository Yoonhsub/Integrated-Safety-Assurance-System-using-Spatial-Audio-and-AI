from __future__ import annotations

import math
import os
import re
import string
from dataclasses import dataclass
from difflib import SequenceMatcher
from typing import Iterable

import httpx

from app.schemas.v3 import (
    DestinationCandidate,
    DestinationCandidateType,
    DestinationResolveResponse,
    DestinationResolveStatus,
    FallbackSource,
    NearbyStopCandidate,
)
from app.services.cheongju_bus_stops_service import CheongjuBusStopMatch, CheongjuBusStopsService


_CONFIRMATION_THRESHOLD = 0.72
_RESOLVED_THRESHOLD = 0.92
_CHOICE_DELTA = 0.04

# 청주 시내 중심부를 기준으로 Local Search 결과가 과도하게 멀리 튀는 것을 완화한다.
_CHEONGJU_CENTER_LAT = 36.6424
_CHEONGJU_CENTER_LNG = 127.4890
_CHEONGJU_LOCAL_SEARCH_RADIUS_METERS = 20_000
_LOCAL_AREA_DESTINATION_KEYWORDS = frozenset({"성안길"})
_STT_CONFIRMATION_ALIASES = {
    "상단산성": "상당산성",
    "산창사거리": "사창사거리",
}


@dataclass(frozen=True)
class _KnownPlace:
    name: str
    type: DestinationCandidateType
    latitude: float
    longitude: float
    aliases: tuple[str, ...] = ()
    address: str | None = None
    confidence: float = 0.95
    stop_id: str | None = None


@dataclass(frozen=True)
class _SeedStop:
    stop_id: str
    stop_name: str
    latitude: float
    longitude: float
    aliases: tuple[str, ...] = ()
    direction_hint: str | None = None


_KNOWN_PLACES: tuple[_KnownPlace, ...] = (
    _KnownPlace(
        name="상당산성",
        type=DestinationCandidateType.PLACE,
        latitude=36.6612,
        longitude=127.5348,
        aliases=("청주상당산성", "상당 산성", "상단산성", "상당산성가"),
        address="충청북도 청주시 상당구 산성동",
        confidence=0.95,
    ),
    _KnownPlace(
        name="사창사거리",
        type=DestinationCandidateType.STOP,
        latitude=36.6359,
        longitude=127.4597,
        aliases=("사창 사거리", "사직사거리", "사창"),
        stop_id="mock-stop-001",
        confidence=0.94,
    ),
    _KnownPlace(
        name="충북대학교병원",
        type=DestinationCandidateType.PLACE,
        latitude=36.6242,
        longitude=127.4613,
        aliases=("충북대병원", "충대병원", "충북대학교 병원"),
        address="충청북도 청주시 서원구 1순환로 776",
        stop_id="mock-stop-002",
        confidence=0.93,
    ),
    _KnownPlace(
        name="청주고속버스터미널",
        type=DestinationCandidateType.PLACE,
        latitude=36.6262,
        longitude=127.4312,
        aliases=("고속버스터미널", "청주터미널", "터미널"),
        address="충청북도 청주시 흥덕구 가경동",
        stop_id="mock-stop-003",
        confidence=0.91,
    ),
    _KnownPlace(
        name="청주시외버스터미널",
        type=DestinationCandidateType.PLACE,
        latitude=36.6270,
        longitude=127.4300,
        aliases=("시외버스터미널", "청주시외터미널", "터미널"),
        address="충청북도 청주시 흥덕구 가경동",
        confidence=0.91,
    ),
    _KnownPlace(
        name="상당구청",
        type=DestinationCandidateType.PLACE,
        latitude=36.5515,
        longitude=127.5005,
        aliases=("상당구청", "청주시상당구청"),
        address="충청북도 청주시 상당구 단재로 466",
        stop_id="mock-stop-004",
        confidence=0.95,
    ),
)


_SEED_STOPS: tuple[_SeedStop, ...] = (
    _SeedStop(
        stop_id="mock-stop-001",
        stop_name="사창사거리 정류장",
        latitude=36.63594787,
        longitude=127.4596675,
        aliases=("사창사거리", "사창 사거리"),
        direction_hint="청주체육관·시청 방면",
    ),
    _SeedStop(
        stop_id="mock-stop-002",
        stop_name="충북대학교병원 정류장",
        latitude=36.6242,
        longitude=127.4613,
        aliases=("충북대병원", "충북대학교병원"),
        direction_hint="개신오거리·충북대 방면",
    ),
    _SeedStop(
        stop_id="mock-stop-003",
        stop_name="청주고속버스터미널 정류장",
        latitude=36.6262,
        longitude=127.4312,
        aliases=("청주고속버스터미널", "고속버스터미널", "청주터미널"),
        direction_hint="가경터미널 방면",
    ),
    _SeedStop(
        stop_id="seed-stop-sangdang-south-gate",
        stop_name="산성남문 정류장",
        latitude=36.6587,
        longitude=127.5360,
        aliases=("상당산성", "산성남문", "청주상당산성"),
        direction_hint="산성남문 방향",
    ),
    _SeedStop(
        stop_id="seed-stop-sangdang-fortress",
        stop_name="상당산성 정류장",
        latitude=36.6613,
        longitude=127.5329,
        aliases=("상당산성", "상당산성입구"),
        direction_hint="상당산성 방향",
    ),
    _SeedStop(
        stop_id="mock-stop-004",
        stop_name="상당구청 정류장",
        latitude=36.5515,
        longitude=127.5005,
        aliases=("상당구청",),
        direction_hint="효촌 방면",
    ),
)


class KakaoLocalSearchProvider:
    """Kakao Local API 기반 장소/주소 검색 provider.

    환경변수 ``KAKAO_REST_API_KEY``가 없거나 ``KAKAO_LOCAL_SEARCH_ENABLED``가 false이면
    비활성화된다. 서버에서만 호출하므로 REST API 키가 Flutter 클라이언트로 노출되지 않는다.
    """

    def __init__(self, *, client: httpx.Client | None = None) -> None:
        try:
            timeout = float(os.getenv("LOCAL_SEARCH_TIMEOUT_SECONDS", "5.0"))
        except ValueError:
            timeout = 5.0
        self._client = client or httpx.Client(timeout=timeout)

    @staticmethod
    def is_enabled() -> bool:
        enabled = os.getenv("KAKAO_LOCAL_SEARCH_ENABLED", "false").strip().lower()
        return enabled in {"true", "1", "yes", "on"} and bool(os.getenv("KAKAO_REST_API_KEY", "").strip())

    def search(
        self,
        query: str,
        *,
        origin_lat: float | None = None,
        origin_lng: float | None = None,
        limit: int = 5,
    ) -> list[DestinationCandidate]:
        if not self.is_enabled():
            return []

        out: list[DestinationCandidate] = []
        if _looks_like_address(query):
            out.extend(self._search_address(query, limit=limit))

        remaining = max(0, limit - len(out))
        if remaining:
            out.extend(
                self._search_keyword(
                    query,
                    origin_lat=origin_lat,
                    origin_lng=origin_lng,
                    limit=remaining,
                )
            )
        candidates = _dedupe_candidates(out)[:limit]
        return _canonicalize_area_destination(query, candidates)

    def _headers(self) -> dict[str, str]:
        return {"Authorization": f"KakaoAK {os.getenv('KAKAO_REST_API_KEY', '').strip()}"}

    def _search_keyword(
        self,
        query: str,
        *,
        origin_lat: float | None,
        origin_lng: float | None,
        limit: int,
    ) -> list[DestinationCandidate]:
        params: dict[str, str | int] = {
            "query": query,
            "size": min(max(limit, 1), 15),
            "page": 1,
            # This backend serves Cheongju guidance. Bias Local results to the
            # user's Cheongju-area origin and reject unrelated national hits.
            "sort": "distance",
            "radius": _CHEONGJU_LOCAL_SEARCH_RADIUS_METERS,
        }
        # 좌표가 없으면 청주 중심부 기준으로 검색 bias를 준다.
        params["x"] = str(origin_lng if origin_lng is not None else _CHEONGJU_CENTER_LNG)
        params["y"] = str(origin_lat if origin_lat is not None else _CHEONGJU_CENTER_LAT)
        try:
            response = self._client.get(
                "https://dapi.kakao.com/v2/local/search/keyword.json",
                params=params,
                headers=self._headers(),
            )
            response.raise_for_status()
            documents = response.json().get("documents", [])
        except Exception:
            return []

        normalized_query = _normalize(query)
        candidates: list[DestinationCandidate] = []
        for doc in documents:
            try:
                name = str(doc.get("place_name") or doc.get("address_name") or "").strip()
                lng = float(doc["x"])
                lat = float(doc["y"])
            except (KeyError, TypeError, ValueError):
                continue
            if _distance_meters(
                origin_lat if origin_lat is not None else _CHEONGJU_CENTER_LAT,
                origin_lng if origin_lng is not None else _CHEONGJU_CENTER_LNG,
                lat,
                lng,
            ) > _CHEONGJU_LOCAL_SEARCH_RADIUS_METERS:
                continue
            if not _keyword_document_matches(query, doc):
                continue
            if not name:
                continue
            # 카카오는 캠퍼스/단지 시설을 "단지.건물"(예: "청주대학교.뉴시스")로 표기한다.
            # 사용자가 단지명만 말했다면 건물 꼬리표를 떼어 단지명으로 정규화해, 엉뚱한
            # 건물 POI("청주대학교.뉴시스")가 목적지로 잡혀 되묻던 문제를 막는다.
            if "." in name:
                prefix = name.split(".", 1)[0].strip()
                if prefix and _normalize(prefix) == normalized_query:
                    name = prefix
            # 이름 유사도로 신뢰도를 매겨 '정확히 같은 이름'이 부분 일치보다 우선되게 한다.
            # (모든 카카오 결과를 0.90으로 고정하면 "충북대학교"가 "충북대학교병원"이나
            # "청주대학교.뉴시스" 같은 부분 일치를 이기지 못해 불필요한 재확인/오안내가 떴다.)
            confidence = round(
                max(0.85, _alias_score(normalized_query, _normalize(name), is_primary=True)),
                2,
            )
            candidates.append(
                DestinationCandidate(
                    name=name,
                    type=DestinationCandidateType.PLACE,
                    confidence=confidence,
                    latitude=lat,
                    longitude=lng,
                    address=str(doc.get("road_address_name") or doc.get("address_name") or "") or None,
                    source=FallbackSource.PUBLIC_API,
                )
            )
        return candidates

    def _search_address(self, query: str, *, limit: int) -> list[DestinationCandidate]:
        try:
            response = self._client.get(
                "https://dapi.kakao.com/v2/local/search/address.json",
                params={"query": query, "size": min(max(limit, 1), 30)},
                headers=self._headers(),
            )
            response.raise_for_status()
            documents = response.json().get("documents", [])
        except Exception:
            return []

        candidates: list[DestinationCandidate] = []
        for doc in documents:
            try:
                address = str(doc.get("address_name") or "").strip()
                lng = float(doc["x"])
                lat = float(doc["y"])
            except (KeyError, TypeError, ValueError):
                continue
            if _distance_meters(
                _CHEONGJU_CENTER_LAT,
                _CHEONGJU_CENTER_LNG,
                lat,
                lng,
            ) > _CHEONGJU_LOCAL_SEARCH_RADIUS_METERS:
                continue
            if not address:
                continue
            candidates.append(
                DestinationCandidate(
                    name=address,
                    type=DestinationCandidateType.ADDRESS,
                    confidence=0.91,
                    latitude=lat,
                    longitude=lng,
                    address=address,
                    source=FallbackSource.PUBLIC_API,
                )
            )
        return candidates


class DestinationCandidateResolver:
    """목적지 발화를 장소명/주소/정류장명 후보로 해석하고 주변 정류장 후보를 반환한다."""

    def __init__(
        self,
        *,
        stop_catalog: CheongjuBusStopsService | None = None,
        local_search: KakaoLocalSearchProvider | None = None,
    ) -> None:
        self._stop_catalog = stop_catalog or CheongjuBusStopsService()
        self._local_search = local_search or KakaoLocalSearchProvider()

    def resolve(
        self,
        *,
        heard_text: str,
        origin_lat: float | None = None,
        origin_lng: float | None = None,
        live: bool = False,
    ) -> DestinationResolveResponse:
        cleaned = _clean_destination_text(heard_text)
        normalized = _normalize(cleaned)
        if not normalized:
            return DestinationResolveResponse(
                status=DestinationResolveStatus.NOT_FOUND,
                heardText=heard_text,
                normalizedText="",
                question="목적지를 다시 말해줘.",
                fallbackSource=FallbackSource.MOCK,
            )

        candidates = self._build_candidates(
            cleaned,
            normalized=normalized,
            origin_lat=origin_lat,
            origin_lng=origin_lng,
            live=live,
        )
        candidates = _dedupe_candidates(sorted(candidates, key=lambda item: item.confidence, reverse=True))

        if not candidates:
            return DestinationResolveResponse(
                status=DestinationResolveStatus.NOT_FOUND,
                heardText=heard_text,
                normalizedText=normalized,
                question=f"{cleaned}{_subject_particle(cleaned)} 아직 찾지 못했어. 장소명이나 주소를 조금 더 정확히 말해줘.",
                fallbackSource=FallbackSource.ERROR if live else FallbackSource.MOCK,
            )

        top = candidates[0]
        destination_stops = self._destination_stops_for(top, live=live)
        origin_stops = self._origin_stops(origin_lat=origin_lat, origin_lng=origin_lng, live=live)

        status = DestinationResolveStatus.RESOLVED
        question: str | None = None

        close_choices = [
            item
            for item in candidates[:5]
            if item.name != top.name and top.confidence - item.confidence <= _CHOICE_DELTA
        ]
        exact_top_name = (
            _normalize(top.name) == normalized
            or _is_unambiguous_known_alias(normalized, top.name)
        )
        _norm_top = _normalize(top.name)
        # 후보 이름이 사용자 발화와 글자 그대로 같거나(verbatim), 발화 안에 후보
        # 이름이 통째로 들어 있으면(예: "상당구청으로", "상당구청 가") 확정으로 본다.
        # (자기가 방금 말한 "상당구청"을 "혹시 상당구청 맞아?"로 되묻는 멍청함 방지)
        verbatim_match = _norm_top == normalized or (
            len(_norm_top) >= 3 and _norm_top in normalized
        )
        if verbatim_match or (exact_top_name and not close_choices):
            status = DestinationResolveStatus.RESOLVED
        elif exact_top_name and top.confidence >= 0.90:
            status = DestinationResolveStatus.RESOLVED
        elif len(close_choices) >= 1 and top.confidence < 0.94:
            # 같은 표시 이름이 서로 다른 source/stopId로 들어와 "충북대학교 / 충북대학교"처럼
            # 중복 노출되던 문제를 막기 위해 표시 이름 기준으로 한 번 더 중복을 제거한다.
            choice_names: list[str] = []
            for item in [top, *close_choices]:
                if item.name not in choice_names:
                    choice_names.append(item.name)
            if len(choice_names) <= 1:
                # 실질 후보가 하나뿐이면 되묻지 않고 확정한다.
                status = DestinationResolveStatus.RESOLVED
            else:
                status = DestinationResolveStatus.NEEDS_CHOICE
                question = f"{' / '.join(choice_names[:3])} 중 어디로 갈까?"
        elif top.confidence < _RESOLVED_THRESHOLD or _normalize(top.name) != normalized and top.confidence < 0.95:
            status = DestinationResolveStatus.NEEDS_CONFIRMATION
            # 받침 유무에 따라 '이/가'가 달라지는 문제를 피하려고 조사 없이 묻는다.
            question = f"혹시 {top.name} 맞아?"

        if top.latitude is None or top.longitude is None:
            status = DestinationResolveStatus.NOT_FOUND
            question = f"{top.name}의 위치 좌표를 확인하지 못했어. 장소명이나 주소를 조금 더 정확히 말해줘."
        elif not destination_stops:
            status = DestinationResolveStatus.NOT_FOUND
            question = f"{top.name} 주변 하차 정류장을 찾지 못했어. 목적지를 조금 더 정확히 말해줘."

        fallback_source = (
            FallbackSource.PUBLIC_API
            if any(item.source == FallbackSource.PUBLIC_API for item in [top, *destination_stops, *origin_stops])
            else FallbackSource.MOCK
        )

        return DestinationResolveResponse(
            status=status,
            heardText=heard_text,
            normalizedText=normalized,
            topCandidate=top,
            candidates=candidates[:5],
            question=question,
            originStops=origin_stops,
            destinationStops=destination_stops,
            fallbackSource=fallback_source,
        )

    def _build_candidates(
        self,
        query: str,
        *,
        normalized: str,
        origin_lat: float | None,
        origin_lng: float | None,
        live: bool,
    ) -> list[DestinationCandidate]:
        candidates: list[DestinationCandidate] = []

        known_candidates = _known_place_candidates(normalized)
        seed_candidates = _seed_stop_name_candidates(normalized)

        if live:
            candidates.extend(
                self._verified_live_known_candidates(
                    known_candidates,
                    normalized=normalized,
                    origin_lat=origin_lat,
                    origin_lng=origin_lng,
                )
            )
            # 실 API 모드에서 오타로 추론한 seed 정류장을 임의 좌표로 확정하지 않는다.
            # 사용자가 정확히 말한 seed 이름만 보존하고, 오타 후보는 승인 카탈로그로
            # 검증된 known place 흐름에서만 확인 질문으로 올린다.
            candidates.extend(
                item
                for item in seed_candidates
                if _normalize(item.name) == normalized
            )
            candidates.extend(self._public_stop_candidates(query))
            candidates.extend(
                self._local_search.search(
                    query,
                    origin_lat=origin_lat,
                    origin_lng=origin_lng,
                    limit=5,
                )
            )
        else:
            candidates.extend(known_candidates)
            candidates.extend(seed_candidates)

        return [item for item in candidates if item.confidence >= _CONFIRMATION_THRESHOLD]

    def _verified_live_known_candidates(
        self,
        candidates: list[DestinationCandidate],
        *,
        normalized: str,
        origin_lat: float | None,
        origin_lng: float | None,
    ) -> list[DestinationCandidate]:
        verified: list[DestinationCandidate] = []
        for candidate in candidates:
            if (
                _normalize(candidate.name) == normalized
                or _is_unambiguous_known_alias(normalized, candidate.name)
            ):
                verified.append(candidate)
                continue
            public_candidate = self._verify_inferred_candidate(
                candidate,
                origin_lat=origin_lat,
                origin_lng=origin_lng,
            )
            if public_candidate is not None:
                verified.append(public_candidate)
        return verified

    def _verify_inferred_candidate(
        self,
        candidate: DestinationCandidate,
        *,
        origin_lat: float | None,
        origin_lng: float | None,
    ) -> DestinationCandidate | None:
        """오타 추론 후보를 청주 승인 정류장/Kakao 결과로 재검증한다."""
        target = _normalize(candidate.name)
        try:
            matches = self._stop_catalog.search_by_name(stop_name=candidate.name, limit=5)
        except Exception:
            matches = []
        stop_match = next(
            (
                item
                for item in matches
                if target == _normalize(item.stop_name)
                or target in _normalize(item.stop_name)
            ),
            None,
        )
        if stop_match is not None:
            return candidate.model_copy(
                update={
                    "latitude": stop_match.latitude,
                    "longitude": stop_match.longitude,
                    "source": FallbackSource.PUBLIC_API,
                }
            )

        try:
            local_matches = self._local_search.search(
                candidate.name,
                origin_lat=origin_lat,
                origin_lng=origin_lng,
                limit=5,
            )
        except Exception:
            local_matches = []
        local_match = next(
            (
                item
                for item in local_matches
                if target == _normalize(item.name)
                or target in _normalize(item.name)
            ),
            None,
        )
        if local_match is None:
            return None
        return candidate.model_copy(
            update={
                "latitude": local_match.latitude,
                "longitude": local_match.longitude,
                "address": local_match.address,
                "source": FallbackSource.PUBLIC_API,
            }
        )

    def _public_stop_candidates(self, query: str) -> list[DestinationCandidate]:
        try:
            matches = self._stop_catalog.search_by_name(stop_name=query, limit=5)
        except Exception:
            return []

        return [
            DestinationCandidate(
                name=match.stop_name,
                type=DestinationCandidateType.STOP,
                confidence=0.93 if _normalize(match.stop_name) == _normalize(query) else 0.86,
                latitude=match.latitude,
                longitude=match.longitude,
                stopId=match.service_id,
                source=FallbackSource.PUBLIC_API,
            )
            for match in matches
        ]

    def _destination_stops_for(
        self,
        candidate: DestinationCandidate,
        *,
        live: bool,
    ) -> list[NearbyStopCandidate]:
        if candidate.latitude is None or candidate.longitude is None:
            return []

        public_matches: list[CheongjuBusStopMatch] = []
        if live:
            try:
                public_matches = self._stop_catalog.find_nearby(
                    origin_lat=candidate.latitude,
                    origin_lng=candidate.longitude,
                    limit=6,
                    radius_meters=1200.0,
                )
                if not public_matches and candidate.type == DestinationCandidateType.STOP and candidate.stopId:
                    public_matches = self._stop_catalog.search_by_name(stop_name=candidate.name, limit=5)
            except Exception:
                public_matches = []

        if public_matches:
            return [_nearby_from_public(match) for match in public_matches]

        return _seed_stops_near(
            lat=candidate.latitude,
            lng=candidate.longitude,
            query=candidate.name,
            limit=5,
            radius_meters=1600.0,
        )

    def _origin_stops(
        self,
        *,
        origin_lat: float | None,
        origin_lng: float | None,
        live: bool,
    ) -> list[NearbyStopCandidate]:
        if origin_lat is None or origin_lng is None:
            return []

        if live:
            try:
                matches = self._stop_catalog.find_nearby(
                    origin_lat=origin_lat,
                    origin_lng=origin_lng,
                    limit=6,
                    radius_meters=900.0,
                )
            except Exception:
                matches = []
            if matches:
                return [_nearby_from_public(match) for match in matches]

        return _seed_stops_near(
            lat=origin_lat,
            lng=origin_lng,
            query=None,
            limit=5,
            radius_meters=1000.0,
        )


def _known_place_candidates(normalized: str) -> list[DestinationCandidate]:
    out: list[DestinationCandidate] = []
    for place in _KNOWN_PLACES:
        name_norm = _normalize(place.name)
        normalized_aliases = [_normalize(alias) for alias in place.aliases]
        alias_scores = [
            _alias_score(normalized, _normalize(alias), is_primary=False)
            for alias in place.aliases
        ]
        score = max([_alias_score(normalized, name_norm, is_primary=True), *alias_scores])
        if normalized in normalized_aliases and normalized not in _STT_CONFIRMATION_ALIASES:
            score = max(score, 0.95)
        if _STT_CONFIRMATION_ALIASES.get(normalized) == place.name:
            score = max(score, 0.94)
        if score < _CONFIRMATION_THRESHOLD:
            continue
        out.append(
            DestinationCandidate(
                name=place.name,
                type=place.type,
                confidence=min(place.confidence, score),
                latitude=place.latitude,
                longitude=place.longitude,
                address=place.address,
                stopId=place.stop_id,
                source=FallbackSource.MOCK,
            )
        )
    return out


def _is_unambiguous_known_alias(normalized: str, candidate_name: str) -> bool:
    if normalized in _STT_CONFIRMATION_ALIASES:
        return False
    matches = [
        place.name
        for place in _KNOWN_PLACES
        if normalized in {_normalize(alias) for alias in place.aliases}
    ]
    return matches == [candidate_name]


def _seed_stop_name_candidates(normalized: str) -> list[DestinationCandidate]:
    out: list[DestinationCandidate] = []
    for stop in _SEED_STOPS:
        names = (stop.stop_name, *stop.aliases)
        score = max(_alias_score(normalized, _normalize(name), is_primary=True) for name in names)
        if score < _CONFIRMATION_THRESHOLD:
            continue
        out.append(
            DestinationCandidate(
                name=stop.stop_name,
                type=DestinationCandidateType.STOP,
                confidence=min(0.91, score),
                latitude=stop.latitude,
                longitude=stop.longitude,
                stopId=stop.stop_id,
                source=FallbackSource.MOCK,
            )
        )
    return out


def _alias_score(query: str, candidate: str, *, is_primary: bool) -> float:
    if not query or not candidate:
        return 0.0
    if query == candidate:
        return 0.99 if is_primary else 0.90
    if query in candidate or candidate in query:
        return 0.94 if is_primary else 0.88
    return SequenceMatcher(None, query, candidate).ratio()


def _seed_stops_near(
    *,
    lat: float,
    lng: float,
    query: str | None,
    limit: int,
    radius_meters: float,
) -> list[NearbyStopCandidate]:
    query_norm = _normalize(query or "")
    scored: list[tuple[float, float, _SeedStop]] = []
    for stop in _SEED_STOPS:
        distance = _distance_meters(lat, lng, stop.latitude, stop.longitude)
        alias_match = query_norm and any(
            query_norm in _normalize(alias) or _normalize(alias) in query_norm
            for alias in (stop.stop_name, *stop.aliases)
        )
        if distance <= radius_meters or alias_match:
            scored.append((0 if alias_match else 1, distance, stop))

    scored.sort(key=lambda item: (item[0], item[1]))
    return [
        NearbyStopCandidate(
            stopId=stop.stop_id,
            stopName=stop.stop_name,
            latitude=stop.latitude,
            longitude=stop.longitude,
            distanceMeters=round(distance, 1),
            source=FallbackSource.MOCK,
            directionHint=stop.direction_hint,
            sideHint=None,
            visionRequiredForSideHint=False,
            crossStreetHint=None,
        )
        for _, distance, stop in scored[:limit]
    ]


def _nearby_from_public(match: CheongjuBusStopMatch) -> NearbyStopCandidate:
    return NearbyStopCandidate(
        stopId=match.service_id,
        stopName=match.stop_name,
        latitude=match.latitude,
        longitude=match.longitude,
        distanceMeters=round(match.distance_meters, 1) if match.distance_meters is not None else None,
        source=FallbackSource.PUBLIC_API,
        directionHint=None,
        sideHint=None,
        visionRequiredForSideHint=False,
        crossStreetHint=None,
    )


def _dedupe_candidates(candidates: Iterable[DestinationCandidate]) -> list[DestinationCandidate]:
    seen: set[tuple[str, str | None]] = set()
    out: list[DestinationCandidate] = []
    for item in candidates:
        key = (_normalize(item.name), item.stopId)
        if key in seen:
            continue
        seen.add(key)
        out.append(item)
    return out


def _keyword_document_matches(query: str, document: dict[str, object]) -> bool:
    normalized = _normalize(query)
    return bool(
        normalized
        and any(
            normalized in _normalize(str(document.get(field) or ""))
            for field in ("place_name", "road_address_name", "address_name")
        )
    )


def _canonicalize_area_destination(
    query: str,
    candidates: list[DestinationCandidate],
) -> list[DestinationCandidate]:
    normalized = _normalize(query)
    if normalized not in _LOCAL_AREA_DESTINATION_KEYWORDS or not candidates:
        return candidates

    def area_rank(candidate: DestinationCandidate) -> tuple[int, int]:
        name = _normalize(candidate.name)
        return (
            0 if "상점가" in name else 1,
            0 if name.startswith(normalized) else 1,
        )

    representative = min(candidates, key=area_rank)
    return [
        DestinationCandidate(
            name=query.strip(),
            type=DestinationCandidateType.PLACE,
            confidence=0.94,
            latitude=representative.latitude,
            longitude=representative.longitude,
            address=representative.address,
            source=FallbackSource.PUBLIC_API,
        )
    ]


def _subject_particle(value: str) -> str:
    if not value:
        return "은"
    code = ord(value[-1])
    if 0xAC00 <= code <= 0xD7A3:
        return "은" if (code - 0xAC00) % 28 else "는"
    return "은"


def _looks_like_address(text: str) -> bool:
    compact = text.strip()
    return bool(
        re.search(r"\d", compact)
        or re.search(r"(로|길|번길|동|읍|면|구|시|군|번지)", compact)
    )


def _clean_destination_text(text: str) -> str:
    cleaned = text.strip()
    cleaned = re.sub(r"^(자비스|모비|mobi|MOBI)[야아,\s]*", "", cleaned)
    cleaned = re.sub(r"^(나|나는|난|저|저는|내가|제가)\s+", "", cleaned).strip()
    # correction utterance: "A가 아니라 B야" means B should be used.
    if "아니라" in cleaned:
        cleaned = cleaned.split("아니라", 1)[1].strip()
    patterns = [
        r"(으로|로)?\s*가고\s*싶어.*$",
        r"(으로|로)?\s*가야\s*(하는데|돼|해)?.*$",
        r"(으로|로)?\s*가자.*$",
        r"(으로|로)?\s*가는\s*(법|길|버스|노선).*$",
        r"(까지)?\s*어떻게\s*가.*$",
        r"(까지)?\s*몇\s*번.*$",
        r"(까지)?\s*몇번.*$",
        r"(까지)?\s*안내해\s*줘.*$",
        r"(까지)?\s*데려다\s*줘.*$",
        r"(으로|로)?\s*바꿔\s*줘.*$",
    ]
    for pattern in patterns:
        cleaned = re.sub(pattern, "", cleaned).strip()
    cleaned = cleaned.strip(string.whitespace + ".,?!~…")
    cleaned = re.sub(r"(이야|야|입니다|이에요|예요)$", "", cleaned).strip()
    cleaned = re.sub(r"(으로|로|까지|에)$", "", cleaned).strip()
    return cleaned or text.strip()


def _normalize(value: str) -> str:
    text = value.lower()
    text = text.replace("정류장", "")
    text = re.sub(r"[\s\-_.,?!~…'\"“”‘’(){}\[\]]+", "", text)
    text = re.sub(r"(으로|로|까지|에)$", "", text)
    return text


def _distance_meters(lat1: float, lng1: float, lat2: float, lng2: float) -> float:
    radius = 6371000.0
    phi1 = math.radians(lat1)
    phi2 = math.radians(lat2)
    d_phi = math.radians(lat2 - lat1)
    d_lambda = math.radians(lng2 - lng1)
    a = (
        math.sin(d_phi / 2) ** 2
        + math.cos(phi1) * math.cos(phi2) * math.sin(d_lambda / 2) ** 2
    )
    return 2 * radius * math.atan2(math.sqrt(a), math.sqrt(1 - a))
