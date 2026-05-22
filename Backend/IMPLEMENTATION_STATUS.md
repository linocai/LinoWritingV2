# Backend v1 Implementation Status

## Implemented Endpoints

- `GET /api/v1/health`
- `GET /api/v1/books`
- `POST /api/v1/books`
- `GET /api/v1/books/{book_id}`
- `PATCH /api/v1/books/{book_id}`
- `DELETE /api/v1/books/{book_id}`
- `POST /api/v1/books/{book_id}/touch`
- `GET /api/v1/books/{book_id}/characters`
- `POST /api/v1/books/{book_id}/characters`
- `GET /api/v1/characters/{character_id}`
- `PATCH /api/v1/characters/{character_id}`
- `DELETE /api/v1/characters/{character_id}`
- `GET /api/v1/characters/{character_id}/timeline`
- `GET /api/v1/books/{book_id}/chapters`
- `POST /api/v1/books/{book_id}/chapters`
- `GET /api/v1/chapters/{chapter_id}`
- `PATCH /api/v1/chapters/{chapter_id}`
- `DELETE /api/v1/chapters/{chapter_id}`
- `POST /api/v1/chapters/{chapter_id}/expand`
- `POST /api/v1/chapters/{chapter_id}/write`
- `POST /api/v1/chapters/{chapter_id}/finalize`
- `POST /api/v1/chapters/{chapter_id}/reopen`
- `GET /api/v1/admin/logs`

## Known Deviations

- Tests use SQLite for speed; PostgreSQL compatibility is covered by SQLAlchemy models and Alembic migration shape.

## Verification

- 2026-05-22: `pytest` from `Backend/` passed, `12 passed in 0.27s`.
- 2026-05-22: `API_TOKEN=test-token-value DATABASE_URL=sqlite+pysqlite:////tmp/lino_writing_migration_test3.db alembic upgrade head` passed.
- 2026-05-22: OpenAPI generation passed (`Lino Writing v2 Backend`, 14 path entries).
- Before running a real service, set `.env`, then run `alembic upgrade head` against the configured database.
