# Lino Writing v2 Backend

FastAPI backend for Lino Writing v2. Project authority document: `../PROJECT_PLAN.md`.

## Local Setup (SQLite, fastest)

```bash
cd Backend
python3.11 -m venv .venv
. .venv/bin/activate
pip install -e ".[dev]"
cp .env.example .env
# edit .env: set API_TOKEN (required, ≥16 chars) and KEK_SECRET (required); GROK_API_KEY is optional (ProviderKey table now preferred)
alembic upgrade head
uvicorn app.main:app --reload --port 8787
```

Health check (v1.0.1: auth is a single fixed shared secret — every request
carries `Authorization: Bearer <API_TOKEN>`, compared constant-time against the
`API_TOKEN` env-var. The v0.9 device-pairing subsystem was removed):

```bash
curl -H "Authorization: Bearer <API_TOKEN>" http://localhost:8787/api/v1/health
```

OpenAPI is served by FastAPI at `/docs` and `/openapi.json`.

## Local PG dialect check (optional, S-1 work)

If you want to verify Postgres-specific code paths locally before HZ cutover:

```bash
docker run -d --name lino-pg-dev -p 5432:5432 \
    -e POSTGRES_USER=lino -e POSTGRES_PASSWORD=lino -e POSTGRES_DB=lino \
    postgres:16
export DATABASE_URL=postgresql+psycopg://lino:lino@127.0.0.1:5432/lino
alembic upgrade head
pytest -W error
```

This is the only Docker we need for dev; production runs without containers (see Deployment).

## Tests

```bash
pytest
```

Tests default to an in-memory SQLite database and `MockLLMClient`. To run the same suite against Postgres, set `DATABASE_URL=postgresql+psycopg://...` as above. Live LLM calls are not part of the default test suite.

## Deployment

Production target: **HZ alibaba cloud ECS** (`118.178.122.194`, hostname `hz`) at `https://lw.linotsai.top`. The deployment story is **systemd + Nginx + certbot + the existing `postgresql@16-main` instance**, sharing the same neighbour pattern as `linofinance-api` / `100j-api` already running on the same VM. There is no Docker on the production host.

The full design and runbook live in `../PROJECT_PLAN.md §5.S`. The deploy script `deploy/deploy-hz.sh` (to be added during Phase S-2) wraps rsync + alembic + `systemctl reload-or-restart linowriting-api`.

Server-side facts (paths, users, services, certificates) are tracked in `/Users/linotsai/hz_info.md`. **Every server-side change must round-trip through `hz_info.md`.**
