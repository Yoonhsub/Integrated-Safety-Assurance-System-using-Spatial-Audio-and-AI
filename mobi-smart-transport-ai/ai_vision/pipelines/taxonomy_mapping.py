"""Explicit mappings from pretrained COCO labels to project taxonomy classes."""
from __future__ import annotations

# Only COCO labels with a direct, safe semantic match are mapped. In particular,
# person is intentionally excluded by the project's privacy/taxonomy policy.
COCO_TO_PROJECT_CLASS: dict[str, tuple[str, str]] = {
    "bus": ("bus", "버스"),
}


def map_coco_class(class_name: str) -> tuple[str, str] | None:
    """Return the project's (class ID, display name), if the mapping is safe."""
    return COCO_TO_PROJECT_CLASS.get(class_name.strip().lower())
