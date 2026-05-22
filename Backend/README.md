# Lino Writing v2 Backend

FastAPI backend for the first Lino Writing v2 release. The implementation follows `../PLAN_BACKEND.md`.

## Local Setup

```bash
cd Backend
python3.11 -m venv .venv
. .venv/bin/activate
pip install -e ".[dev]"
cp .env.example .env
# edit .env: set API_TOKEN and GROK_API_KEY before starting the app
docker compose up -d postgres
alembic upgrade head
uvicorn app.main:app --reload --port 8787
```

Health check:

```bash
curl -H "Authorization: Bearer <API_TOKEN>" http://localhost:8787/api/v1/health
```

OpenAPI is served by FastAPI at `/docs` and `/openapi.json`.

## Tests

```bash
cd Backend
python3.11 -m venv .venv
. .venv/bin/activate
pip install -e ".[dev]"
pytest
```

Tests use an in-memory SQLite database and `MockLLMClient`. Live Grok calls are not part of the default test suite.

## Deployment

Production compose and TLS proxy files live in `deploy/`:

- `deploy/docker-compose.prod.yml`
- `deploy/Caddyfile`
- `deploy/backup.sh`

Before cloud deployment, set `.env` with `API_TOKEN`, `GROK_API_KEY`, model names, `POSTGRES_PASSWORD`, and `DOMAIN_NAME` for Caddy. The production compose file supplies the container-internal `DATABASE_URL` that points at the `postgres` service.
