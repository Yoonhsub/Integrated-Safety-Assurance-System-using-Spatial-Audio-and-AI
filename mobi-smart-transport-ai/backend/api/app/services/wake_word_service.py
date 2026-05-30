from __future__ import annotations


def detect(utterance: str, wake_word: str) -> tuple[bool, str]:
    """Returns (recognized, normalized_utterance)."""
    stripped = utterance.strip()
    if stripped == wake_word:
        return True, ""
    prefix = wake_word + ","
    if stripped.startswith(prefix):
        return True, stripped[len(prefix):].strip()
    prefix_space = wake_word + " "
    if stripped.startswith(prefix_space):
        return True, stripped[len(prefix_space):].strip()
    return False, stripped
