from __future__ import annotations

from collections.abc import Iterable

from app.errors import conflict
from app.models.chapter import Chapter

CHAPTER_STATUSES = {"draft", "prompt_ready", "writing", "draft_ready", "finalized"}
TIMELINE_EVENT_TYPES = {
    "action",
    "experience",
    "relation_change",
    "secret_learned",
    "ability_gained",
    "state_change",
}


def ensure_chapter_status(chapter: Chapter, allowed: Iterable[str], action: str) -> None:
    allowed_set = set(allowed)
    if chapter.status not in allowed_set:
        raise conflict(
            f"Chapter status '{chapter.status}' cannot perform {action}",
            details={"status": chapter.status, "allowed": sorted(allowed_set), "action": action},
        )
