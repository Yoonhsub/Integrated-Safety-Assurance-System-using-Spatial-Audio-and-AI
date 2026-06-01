from __future__ import annotations

from dataclasses import dataclass

from app.schemas.v3 import RoutePlanCandidate, RoutePlanVerificationStatus


@dataclass(frozen=True)
class RouteRankAssessment:
    score: int
    accessibility_score: float
    simplicity_score: float
    total_estimated_minutes: int | None
    recommended_reason: str
    ranking_evidence: list[str]


class RouteRanker:
    """Ranks route candidates with explicit penalties for uncertain guidance."""

    def assess(self, candidate: RoutePlanCandidate) -> RouteRankAssessment:
        unknown_arrivals = sum(segment.arrivalUnknown for segment in candidate.segments)
        unknown_directions = sum(not segment.directionHint for segment in candidate.segments)
        direct_bonus = 8 if candidate.transferCount == 0 else 0
        total_estimated_minutes = self._estimated_minutes(candidate)
        verification_adjustment = {
            RoutePlanVerificationStatus.VERIFIED_WITH_TAGO: 8,
            RoutePlanVerificationStatus.LOCAL_ONLY: 4,
            RoutePlanVerificationStatus.PARTIAL: -8,
            RoutePlanVerificationStatus.ODSAY_ONLY: -18,
        }[candidate.verificationStatus]
        penalty = (
            candidate.transferCount * 18
            + min(candidate.estimatedWalkMeters // 45, 14)
            + min(candidate.totalBusStopCount, 20)
            + unknown_arrivals * 10
            + unknown_directions * 6
            + (min(total_estimated_minutes // 5, 16) if total_estimated_minutes is not None else 0)
        )
        score = max(0, min(100, 100 + direct_bonus + verification_adjustment - penalty))
        accessibility = max(0.0, min(1.0, 1.0 - candidate.transferCount * 0.22 - candidate.estimatedWalkMeters / 3500))
        simplicity = max(0.0, min(1.0, 1.0 - candidate.transferCount * 0.35 - len(candidate.segments) * 0.04))
        evidence = [
            f"환승 {candidate.transferCount}회",
            f"도보 약 {candidate.estimatedWalkMeters}m",
            f"버스 정류장 {candidate.totalBusStopCount}개",
        ]
        if unknown_arrivals:
            evidence.append(f"도착정보 미확인 {unknown_arrivals}개 구간")
        if unknown_directions:
            evidence.append(f"방향정보 미확인 {unknown_directions}개 구간")
        evidence.append(f"검증 상태 {candidate.verificationStatus.value}")
        if candidate.transferCount == 0:
            reason = "환승 없이 이동할 수 있어 우선 추천합니다."
        elif unknown_arrivals:
            reason = "일부 도착정보를 확인하지 못했지만 이동 조건이 단순한 순서로 추천합니다."
        else:
            reason = "도보 거리와 환승 횟수를 함께 고려해 추천합니다."
        return RouteRankAssessment(
            score=score,
            accessibility_score=accessibility,
            simplicity_score=simplicity,
            total_estimated_minutes=total_estimated_minutes,
            recommended_reason=reason,
            ranking_evidence=evidence,
        )

    def rank(self, candidates: list[RoutePlanCandidate]) -> list[RoutePlanCandidate]:
        assessed: list[RoutePlanCandidate] = []
        for candidate in candidates:
            result = self.assess(candidate)
            assessed.append(
                candidate.model_copy(
                    update={
                        "score": result.score,
                        "accessibilityScore": result.accessibility_score,
                        "simplicityScore": result.simplicity_score,
                        "totalEstimatedMinutes": result.total_estimated_minutes,
                        "recommendedReason": result.recommended_reason,
                        "rankingEvidence": result.ranking_evidence,
                    }
                )
            )
        return sorted(
            assessed,
            key=lambda candidate: (
                -candidate.score,
                candidate.transferCount,
                candidate.estimatedWalkMeters,
                candidate.totalBusStopCount,
                candidate.planId,
            ),
        )

    def _estimated_minutes(self, candidate: RoutePlanCandidate) -> int | None:
        if candidate.totalEstimatedMinutes is not None:
            return candidate.totalEstimatedMinutes
        first_arrivals = [
            segment.arrivals[0].arrivalMinutes
            for segment in candidate.segments
            if segment.arrivals
        ]
        if len(first_arrivals) != len(candidate.segments):
            return None
        ride_minutes = sum(max(1, segment.stopCount * 2) for segment in candidate.segments)
        walk_minutes = max(1, round(candidate.estimatedWalkMeters / 70))
        return sum(first_arrivals) + ride_minutes + walk_minutes
