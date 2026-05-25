from __future__ import annotations

from collections.abc import Iterable

from app.errors import CHAPTER_ACTION_CN, CHAPTER_STATUS_CN, i18n_conflict
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
        # v0.7 §5.N — Chinese template. Falls back to the raw code if the
        # status / action isn't in the CN map (defensive; both maps are
        # kept in sync with CHAPTER_STATUSES + every router action).
        status_cn = CHAPTER_STATUS_CN.get(chapter.status, chapter.status)
        action_cn = CHAPTER_ACTION_CN.get(action, action)
        raise i18n_conflict(
            "chapter_status_invalid_action",
            status_cn=status_cn,
            action_cn=action_cn,
            details={
                "status": chapter.status,
                "allowed": sorted(allowed_set),
                "action": action,
            },
        )
