"""add agent_personas + seed three defaults (v1.0.0 EE Phase 1)

Revision ID: 202606130002
Revises: 202606130001
Create Date: 2026-06-13 00:00:02.000000

v1.0.0 EE Phase 1 (archive/v1.0.0_plan.md §3.3 / §3.4 / §8): DB-stored,
App-editable persona prompt per Agent. Three roles only — expander / writer
/ extractor. Pure add-table plus an inline seed of the three default
personas (``is_default=true``).

The seed prompt strings are inlined here verbatim (NOT imported from
``app.services.personas``): a migration must be a frozen historical fact and
must not drift if the app-level ``DEFAULT_PERSONAS`` constants are later
edited. The runtime ``reset`` path uses the app-level constants; this seed
captures the v1.0.0 launch defaults.

Both PG and SQLite run this on ``alembic upgrade head``: ``op.bulk_insert``
emits dialect-portable parameterised INSERTs.
"""
from __future__ import annotations

from collections.abc import Sequence
from datetime import datetime, timezone

from alembic import op
import sqlalchemy as sa

revision: str = "202606130002"
down_revision: str | None = "202606130001"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


# Seed prompts — frozen copy of the v1.0.0 launch defaults (plan §8). Keep in
# sync semantically with app/services/personas.py DEFAULT_PERSONAS, but this
# literal is the migration's own frozen record.
_EXPANDER = """
[人格] 你是冷静的章节结构师，just-in-time 读整份全书大纲 + 当前结构化记忆，
       定位故事走到哪了，把上下文编译成一条清晰的「本章创作指令」。
[原则] 贴着大纲与已发生的进度走；克制、聚焦；只编译已知信息，不脑补大纲外的新剧情。
[边界] chapter_directive 是方向盘(200–300 字)：写本章要达成什么、张力在哪、承接什么落点、
       注意哪条还开着的伏笔——绝不把人物卡/时间线的内容抄进 directive（知识由 Context Pack 直达 Writer）。
       不发明大纲之外的情节；focus_traits 最多 2 个。
""".strip()

_WRITER = """
[人格] 你是有稳定文风的中文小说家，执行 chapter_directive 把骨架写成血肉。
[边界] 不越权推进 directive 之外的剧情；连贯优先；角色卡是水库不是清单（保留现有 §5.L 规则）。
""".strip()

_EXTRACTOR = """
[人格] 你是一丝不苟的档案员，把本章已发生的事实回写进卡与时间线（append-only）。
[边界] 只记已发生的事实，不演绎、不预测、宁缺毋滥；不改 frozen_fields；不读/不动 author_notes。
""".strip()


def upgrade() -> None:
    personas = op.create_table(
        "agent_personas",
        sa.Column("agent_role", sa.String(length=32), primary_key=True),
        sa.Column("system_prompt", sa.Text(), nullable=False),
        sa.Column("is_default", sa.Boolean(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
    )
    now = datetime.now(timezone.utc)
    op.bulk_insert(
        personas,
        [
            {"agent_role": "expander", "system_prompt": _EXPANDER, "is_default": True, "updated_at": now},
            {"agent_role": "writer", "system_prompt": _WRITER, "is_default": True, "updated_at": now},
            {"agent_role": "extractor", "system_prompt": _EXTRACTOR, "is_default": True, "updated_at": now},
        ],
    )


def downgrade() -> None:
    op.drop_table("agent_personas")
