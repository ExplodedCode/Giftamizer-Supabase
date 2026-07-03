#!/bin/bash
#
# Compares the schema produced by a fresh local install (built from
# volumes/db/*.sql and volumes/db/giftamizer/*.sql) against a live database's
# actual schema (public + storage), so drift gets caught automatically instead
# of being discovered months later.
#
# Usage:
#   ./scripts/check-schema-drift.sh "postgres://user:pass@host:port/dbname"
#   PROD_DB_URL="postgres://..." ./scripts/check-schema-drift.sh
#
# The connection string is never written to disk by this script - pass it
# directly or via an env var each time you run it.

set -euo pipefail
cd "$(dirname "$0")/.."

REMOTE_DB_URL="${1:-${PROD_DB_URL:-}}"
if [ -z "$REMOTE_DB_URL" ]; then
  echo "Usage: $0 <postgres-connection-string>" >&2
  echo "   or: PROD_DB_URL=postgres://... $0" >&2
  exit 1
fi

PROJECT="schema-drift-check"
COMPOSE_FILES=(-f docker-compose.yml -f ./dev/docker-compose.dev.yml -f ./scripts/docker-compose.drift-check.yml)
PG_IMAGE=$(grep -oE 'supabase/postgres:[^[:space:]]+' docker-compose.yml | head -1)
LOCAL_SCHEMA=$(mktemp)
REMOTE_SCHEMA=$(mktemp)

cleanup() {
  docker rm -f db-drift-check >/dev/null 2>&1 || true
  docker compose -p "$PROJECT" --env-file .env.example "${COMPOSE_FILES[@]}" down -v >/dev/null 2>&1 || true
  rm -f "$LOCAL_SCHEMA" "$REMOTE_SCHEMA"
}
trap cleanup EXIT

# In case a previous run was interrupted before cleanup.
docker rm -f db-drift-check >/dev/null 2>&1 || true

echo "==> Booting a throwaway database from volumes/db/*.sql (image: $PG_IMAGE)..."
docker compose -p "$PROJECT" --env-file .env.example "${COMPOSE_FILES[@]}" up -d db >/dev/null

echo "==> Waiting for it to become healthy..."
status="starting"
for _ in $(seq 1 60); do
  status=$(docker inspect --format='{{.State.Health.Status}}' db-drift-check 2>/dev/null || echo "starting")
  [ "$status" = "healthy" ] && break
  sleep 2
done
if [ "$status" != "healthy" ]; then
  echo "Local database never became healthy - aborting. Recent logs:" >&2
  docker logs db-drift-check 2>&1 | tail -50 >&2
  exit 1
fi

normalize() {
  grep -vE '^(--|SET |SELECT pg_catalog\.set_config|\\restrict|\\unrestrict)' | grep -v '^[[:space:]]*$'
}

echo "==> Dumping local (fresh-install) schema..."
docker exec db-drift-check pg_dump -U postgres --schema-only --no-owner --no-privileges \
  --schema=public --schema=storage postgres | normalize > "$LOCAL_SCHEMA"

echo "==> Dumping remote schema..."
docker run --rm "$PG_IMAGE" pg_dump --schema-only --no-owner --no-privileges \
  --schema=public --schema=storage "$REMOTE_DB_URL" | normalize > "$REMOTE_SCHEMA"

echo ""
echo "==> Diff (lines starting with '-' exist only in the remote DB, '+' only in the fresh local install):"
echo ""
if diff -u "$REMOTE_SCHEMA" "$LOCAL_SCHEMA"; then
  echo "No drift detected - public/storage schema matches."
else
  echo ""
  echo "Drift found above. This is a text diff of two independent pg_dump runs, so"
  echo "expect some harmless noise (object ordering, sequence values); focus on"
  echo "added/removed CREATE TABLE/FUNCTION/POLICY/TRIGGER blocks. Patch"
  echo "volumes/db/giftamizer/*.sql to match the remote DB, following the same"
  echo "convention as past reconciliations (see README's 'Updating production' section)."
fi
