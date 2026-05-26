from __future__ import annotations

from collections.abc import Generator

from sqlalchemy import create_engine, event
from sqlalchemy.engine import Engine
from sqlalchemy.orm import DeclarativeBase, Session, sessionmaker
from sqlalchemy.pool import StaticPool

from app.config import get_settings


class Base(DeclarativeBase):
    pass


def make_engine(database_url: str) -> Engine:
    if database_url.startswith("sqlite"):
        connect_args = {"check_same_thread": False}
        if database_url in {"sqlite+pysqlite://", "sqlite://", "sqlite+pysqlite:///:memory:"}:
            return create_engine(
                database_url,
                connect_args=connect_args,
                poolclass=StaticPool,
                future=True,
            )
        return create_engine(database_url, connect_args=connect_args, future=True)
    return create_engine(database_url, pool_pre_ping=True, future=True)


engine = make_engine(get_settings().database_url)
SessionLocal = sessionmaker(bind=engine, autoflush=False, expire_on_commit=False, future=True)


@event.listens_for(Engine, "connect")
def set_sqlite_pragma(dbapi_connection, connection_record) -> None:  # type: ignore[no-untyped-def]
    # v0.8 S-1: gate by dialect. Running ``PRAGMA foreign_keys=ON`` on a
    # Postgres connection silently fails (caught by the bare ``except`` that
    # used to live here), but the failed statement leaves the implicit
    # Postgres transaction in 'aborted' state, blocking every subsequent
    # statement on the same connection until ROLLBACK. Alembic startup
    # discovered this when it tried ``SELECT pg_catalog.version()`` next.
    # Detect SQLite by the dbapi module name (sqlite3 / pysqlite) — both
    # land under the ``sqlite3`` module.
    if not type(dbapi_connection).__module__.startswith("sqlite3"):
        return
    cursor = dbapi_connection.cursor()
    try:
        cursor.execute("PRAGMA foreign_keys=ON")
    finally:
        cursor.close()


def get_db() -> Generator[Session, None, None]:
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
