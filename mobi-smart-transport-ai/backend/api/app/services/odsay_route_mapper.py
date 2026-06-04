from __future__ import annotations

from typing import Any

from app.schemas.v3 import (
    FallbackSource,
    RoutePlanCandidate,
    RoutePlanLeg,
    RoutePlanLegMode,
    RoutePlanSegment,
    RoutePlanSource,
    RoutePlanStop,
    RoutePlanType,
    RoutePlanVerificationStatus,
)
from app.services.odsay_client import OdsayTransitResult
from app.services.route_direction_resolver import sanitize_guidance_text


class OdsayRouteMapper:
    """Defensively maps ODsay provider JSON into the internal RoutePlan contract."""

    def map_result(self, result: OdsayTransitResult, *, destination_name: str) -> list[RoutePlanCandidate]:
        raw_paths = _dict(result.raw_response.get("result")).get("path")
        if not isinstance(raw_paths, list):
            return []

        candidates: list[RoutePlanCandidate] = []
        for index, raw_path in enumerate(raw_paths, start=1):
            candidate = self._map_path(index=index, raw_path=_dict(raw_path), destination_name=destination_name)
            if candidate is not None:
                candidates.append(candidate)
        return candidates

    def _map_path(
        self,
        *,
        index: int,
        raw_path: dict[str, Any],
        destination_name: str,
    ) -> RoutePlanCandidate | None:
        info = _dict(raw_path.get("info"))
        raw_sub_paths = raw_path.get("subPath")
        if not isinstance(raw_sub_paths, list):
            return None

        legs: list[RoutePlanLeg] = []
        segments: list[RoutePlanSegment] = []
        walk_meters = 0.0
        for leg_index, raw_sub_path in enumerate(raw_sub_paths, start=1):
            sub_path = _dict(raw_sub_path)
            mode = _leg_mode(sub_path.get("trafficType"))
            if mode is None:
                continue
            estimated_minutes = _int_or_none(sub_path.get("sectionTime"))
            if mode == RoutePlanLegMode.WALK:
                walk_meters += max(0.0, _float_or_zero(sub_path.get("distance")))
                legs.append(RoutePlanLeg(mode=mode, estimatedMinutes=estimated_minutes, source="ODSAY"))
                continue

            lane = _first_dict(sub_path.get("lane"))
            route_no = _text(lane.get("busNo") or lane.get("name") or sub_path.get("routeNo"))
            provider_route_id = _text(lane.get("busID") or lane.get("busId") or lane.get("subwayCode"))
            boarding_name = _guidance_text(sub_path.get("startName"))
            alighting_name = _guidance_text(sub_path.get("endName"))
            boarding_provider_id = _text(sub_path.get("startID"))
            alighting_provider_id = _text(sub_path.get("endID"))
            boarding_stop_id = _verified_tago_node_id(boarding_provider_id) or f"odsay-unverified-board-{index}-{leg_index}"
            alighting_stop_id = _verified_tago_node_id(alighting_provider_id) or f"odsay-unverified-alight-{index}-{leg_index}"
            legs.append(
                RoutePlanLeg(
                    mode=mode,
                    routeNo=route_no,
                    providerRouteId=provider_route_id,
                    boardingStopName=boarding_name,
                    boardingStopId=boarding_provider_id,
                    alightingStopName=alighting_name,
                    alightingStopId=alighting_provider_id,
                    estimatedMinutes=estimated_minutes,
                    source="ODSAY",
                )
            )
            if mode != RoutePlanLegMode.BUS or not route_no or not boarding_name or not alighting_name:
                continue
            segments.append(
                RoutePlanSegment(
                    routeNo=route_no,
                    routeId=f"odsay-unverified-route-{index}-{leg_index}",
                    source="ODSAY",
                    providerRouteId=provider_route_id,
                    boardStop=RoutePlanStop(
                        stopId=boarding_stop_id,
                        stopName=boarding_name,
                        nodeId=boarding_provider_id,
                        latitude=_float_or_none(sub_path.get("startY") or sub_path.get("startLat") or sub_path.get("startLatitude")),
                        longitude=_float_or_none(sub_path.get("startX") or sub_path.get("startLng") or sub_path.get("startLongitude")),
                        visionRequiredForSideHint=True,
                    ),
                    alightStop=RoutePlanStop(
                        stopId=alighting_stop_id,
                        stopName=alighting_name,
                        nodeId=alighting_provider_id,
                        latitude=_float_or_none(sub_path.get("endY") or sub_path.get("endLat") or sub_path.get("endLatitude")),
                        longitude=_float_or_none(sub_path.get("endX") or sub_path.get("endLng") or sub_path.get("endLongitude")),
                        visionRequiredForSideHint=True,
                    ),
                    stopCount=max(0, _int_or_zero(sub_path.get("stationCount"))),
                    directionHint=None,
                    arrivals=[],
                    arrivalSource=FallbackSource.ERROR,
                    arrivalUnknown=True,
                    estimatedMinutes=estimated_minutes,
                )
            )

        if not segments:
            return None
        transfer_count = max(0, _int_or_zero(info.get("busTransitCount"), default=len(segments) - 1))
        plan_type = RoutePlanType.DIRECT if transfer_count == 0 and len(segments) == 1 else RoutePlanType.ONE_TRANSFER
        warnings = ["TAGO routeId/nodeId 매칭 대기", "실시간 도착정보를 확인하지 못함"]
        return RoutePlanCandidate(
            planId=f"odsay-plan-{index}",
            type=plan_type,
            destinationName=destination_name,
            summary=_summary(plan_type, segments, destination_name),
            boardingInstruction=_unverified_boarding_instruction(segments[0]),
            transferCount=transfer_count,
            totalBusStopCount=sum(segment.stopCount for segment in segments),
            estimatedWalkMeters=round(walk_meters, 1),
            accessibilityScore=0,
            simplicityScore=0,
            score=0,
            totalEstimatedMinutes=_int_or_none(info.get("totalTime")),
            segments=segments,
            fallbackSource=FallbackSource.PUBLIC_API,
            planSource=RoutePlanSource.ODSAY,
            provider="ODSAY",
            verificationStatus=RoutePlanVerificationStatus.ODSAY_ONLY,
            warnings=warnings,
            rawProviderEvidence={
                "provider": "ODSAY",
                "pathType": info.get("trafficDistance"),
                "totalTime": _int_or_none(info.get("totalTime")),
                "payment": _int_or_none(info.get("payment")),
            },
            legs=legs,
        )


def _summary(plan_type: RoutePlanType, segments: list[RoutePlanSegment], destination_name: str) -> str:
    first = segments[0]
    if plan_type == RoutePlanType.DIRECT:
        return f"ODsay 기준 {first.routeNo}번을 이용해 {destination_name}까지 가는 경로야."
    return f"ODsay 기준 버스를 갈아타고 {destination_name}까지 가는 경로야."


def _unverified_boarding_instruction(segment: RoutePlanSegment) -> str:
    return (
        f"{segment.boardStop.stopName}에서 {segment.routeNo}번을 타면 돼. "
        "정류장 방향과 실시간 도착정보는 아직 확인하지 못했어."
    )


def _leg_mode(value: Any) -> RoutePlanLegMode | None:
    try:
        traffic_type = int(value)
    except (TypeError, ValueError):
        return None
    return {
        1: RoutePlanLegMode.SUBWAY,
        2: RoutePlanLegMode.BUS,
        3: RoutePlanLegMode.WALK,
    }.get(traffic_type)


def _dict(value: Any) -> dict[str, Any]:
    return value if isinstance(value, dict) else {}


def _first_dict(value: Any) -> dict[str, Any]:
    if isinstance(value, list) and value and isinstance(value[0], dict):
        return value[0]
    return {}


def _text(value: Any) -> str | None:
    text = str(value).strip() if value is not None else ""
    return text or None


def _guidance_text(value: Any) -> str | None:
    text = _text(value)
    return sanitize_guidance_text(text) if text else None


def _int_or_none(value: Any) -> int | None:
    try:
        return max(0, int(float(value)))
    except (TypeError, ValueError):
        return None


def _int_or_zero(value: Any, *, default: int = 0) -> int:
    parsed = _int_or_none(value)
    return parsed if parsed is not None else default


def _float_or_zero(value: Any) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return 0.0


def _float_or_none(value: Any) -> float | None:
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _verified_tago_node_id(value: str | None) -> str | None:
    if not value:
        return None
    return value if value.upper().startswith("CJB") else None
