# Lino Writing v2 Backend

FastAPI backend for Lino Writing v2. Project authority document: `../PROJECT_PLAN.md`.

## Local Setup (SQLite, fastest)

```bash
cd Backend
python3.11 -m venv .venv
. .venv/bin/activate
pip install -e ".[dev]"
cp .env.example .env
# edit .env: set API_TOKEN (required, ≥16 chars) and KEK_SECRET (required).
# LLM keys are managed in-app via the ProviderKey table, not env vars.
alembic upgrade head
uvicorn app.main:app --reload --port 8787
```

Health check (auth is a single fixed shared secret — every request carries
`Authorization: Bearer <API_TOKEN>`, compared constant-time against the
`API_TOKEN` env-var):

```bash
curl -H "Authorization: Bearer <API_TOKEN>" http://localhost:8787/api/v1/health
```

OpenAPI is served by FastAPI at `/docs` and `/openapi.json`.

## Tests

```bash
pytest
```

Tests default to an in-memory SQLite database and `MockLLMClient`. To run the
same suite against Postgres:

```bash
docker run -d --name lino-pg-dev -p 5432:5432 \
    -e POSTGRES_USER=lino -e POSTGRES_PASSWORD=lino -e POSTGRES_DB=lino \
    postgres:16
export DATABASE_URL=postgresql+psycopg://lino:lino@127.0.0.1:5432/lino
alembic upgrade head
pytest -W error
```

This is the only Docker we need for dev; production runs without containers.

## Deployment

Production: **HZ alibaba cloud ECS** at `https://lw.linotsai.top` — systemd +
Nginx + certbot + PostgreSQL 16, no Docker, **single uvicorn worker (hard
constraint, see `deploy/README.md`)**. Daily releases via
`deploy/deploy-hz.sh` (rsync + alembic + reload).

Server-side facts (paths, users, services, certificates) are tracked in
`/Users/linotsai/hz_info.md`. **Every server-side change must round-trip
through `hz_info.md`.**
