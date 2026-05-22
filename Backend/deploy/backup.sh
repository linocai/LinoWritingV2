#!/usr/bin/env sh
set -eu

: "${POSTGRES_USER:=novelos}"
: "${POSTGRES_DB:=novelos}"
: "${BACKUP_DIR:=./backups}"

mkdir -p "$BACKUP_DIR"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
docker compose exec -T postgres pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB" > "$BACKUP_DIR/lino-writing-$timestamp.sql"
gzip "$BACKUP_DIR/lino-writing-$timestamp.sql"
echo "$BACKUP_DIR/lino-writing-$timestamp.sql.gz"
