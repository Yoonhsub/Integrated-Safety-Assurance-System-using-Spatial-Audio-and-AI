from __future__ import annotations

from app.services.route_stop_sequence_cache import RouteSequence, RouteStopNode


class RouteDirectionResolver:
    """Builds direction hints only from the ordered stop sequence."""

    def direction_hint(
        self,
        sequence: RouteSequence,
        boarding_stop: RouteStopNode,
        alighting_stop: RouteStopNode,
    ) -> str | None:
        downstream = [
            node.stop_name.strip()
            for node in sequence.nodes
            if boarding_stop.order < node.order <= alighting_stop.order and node.stop_name.strip()
        ]
        if not downstream:
            return None
        landmarks: list[str] = []
        for name in (downstream[0], alighting_stop.stop_name.strip()):
            sanitized = sanitize_guidance_text(name)
            if sanitized and sanitized not in landmarks:
                landmarks.append(sanitized)
        return f"{'·'.join(landmarks)} 방향" if landmarks else None


_PROHIBITED_GUIDANCE_TERMS = (
    "도로를 건너",
    "도로 건너",
    "길을 건너",
    "길 건너",
    "횡단보도",
    "왼쪽",
    "오른쪽",
    "건너편",
    "맞은편",
    "반대편",
)


def sanitize_guidance_text(value: str) -> str:
    result = value
    for term in _PROHIBITED_GUIDANCE_TERMS:
        result = result.replace(term, "")
    return " ".join(result.split()).strip(" ,-·")
