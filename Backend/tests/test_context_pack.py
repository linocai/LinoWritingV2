from __future__ import annotations

from app.models.book import Book
from app.models.chapter import Chapter
from app.models.character import Character
from app.models.timeline_event import TimelineEvent
from app.services.context_pack import build_expander_context, build_writer_context


def test_context_pack_filters_characters_and_limits_summaries(db_session):
    book = Book(title="长夜", world_setting="雨城", style_directive="克制")
    db_session.add(book)
    db_session.flush()

    c1 = Character(book_id=book.id, name="林夕", role="主角", frozen_fields={"core_traits": "谨慎"}, live_fields={})
    c2 = Character(book_id=book.id, name="黑刀", role="反派", frozen_fields={"core_traits": "沉默"}, live_fields={})
    db_session.add_all([c1, c2])
    db_session.flush()

    chapter1 = Chapter(book_id=book.id, index=1, user_prompt="一", summary="第一章摘要", status="finalized")
    chapter2 = Chapter(book_id=book.id, index=2, user_prompt="二", summary="第二章摘要", status="finalized")
    chapter3 = Chapter(book_id=book.id, index=3, user_prompt="三", summary="第三章摘要", status="finalized")
    chapter4 = Chapter(
        book_id=book.id,
        index=4,
        user_prompt="四",
        status="prompt_ready",
        structured_prompt={"chapter_goal": "推进", "characters_involved": [c1.id]},
    )
    db_session.add_all([chapter1, chapter2, chapter3, chapter4])
    db_session.flush()
    db_session.add(
        TimelineEvent(
            book_id=book.id,
            character_id=c1.id,
            chapter_id=chapter2.id,
            event_type="action",
            event_text="发现旧信。",
        )
    )
    db_session.commit()

    expander = build_expander_context(db_session, book, chapter4)
    assert [item["index"] for item in expander["recent_summaries"]] == [2, 3]
    assert {item["id"] for item in expander["all_characters"]} == {c1.id, c2.id}

    writer = build_writer_context(db_session, book, chapter4)
    assert [character["id"] for character in writer["characters"]] == [c1.id]
    assert list(writer["timelines"].keys()) == [c1.id]
    assert writer["timelines"][c1.id][0]["event_text"] == "发现旧信。"
