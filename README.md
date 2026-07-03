# Giftamizer Supabase Backend

This repo is the self-hosted [Supabase](https://supabase.com) backend for
[Giftamizer](https://giftamizer.com) — Postgres, Auth, Storage, Realtime,
Edge Functions, and a handful of Giftamizer-specific services, all run via
Docker Compose. It's based on the official
[Supabase self-hosting Docker guide](https://supabase.com/docs/guides/self-hosting/docker).

## Prerequisites

- Docker and Docker Compose v2
- Git

## Local development quick start

```sh
cp .env.example .env
docker compose -f docker-compose.yml -f ./dev/docker-compose.dev.yml up -d
```

This starts the full Supabase stack plus dev conveniences:

- **Studio / API gateway** — http://localhost:8000 (basic auth: `DASHBOARD_USERNAME` / `DASHBOARD_PASSWORD` from `.env`)
- **Inbucket (fake mail server)** — http://localhost:9000, catches all auth emails so you don't need real SMTP locally
- **Postgres Meta** — exposed on `localhost:5555` for direct DB introspection tools

The Giftamizer schema (`profiles`, `groups`, `items`, `lists`, RLS policies,
storage buckets, etc.) is created automatically from
`volumes/db/giftamizer/*.sql` the first time the `db` container initializes
an empty data directory. Sign up through the app (or Studio's Auth panel) to
create a user — the `handle_new_user` trigger sets up their profile and
default list automatically.

Stop the stack with:

```sh
docker compose -f docker-compose.yml -f ./dev/docker-compose.dev.yml down
```

To wipe everything (containers, volumes, and your local `.env`) and start
completely fresh:

```sh
./reset.sh
```

### Giftamizer's extra services (optional)

Production also runs three Giftamizer-specific containers: `smtp2graph`
(SMTP-to-Microsoft-Graph email relay), `urlmetadata` (link preview
metadata), and `firebase-auth-middleware` (legacy Firebase password
verification). These are **not** started by default locally since they need
Azure AD / Firebase credentials. To opt in:

```sh
echo "COMPOSE_PROFILES=giftamizer-extras" >> .env
docker compose -f docker-compose.yml -f ./dev/docker-compose.dev.yml up -d
```

### S3-backed storage (optional)

To test with S3-compatible storage (MinIO) instead of the local filesystem:

```sh
docker compose -f docker-compose.yml -f docker-compose.s3.yml up -d
```

## Repo layout

- `docker-compose.yml` — the full stack; this is also what production runs
- `dev/docker-compose.dev.yml` — local dev overrides (fake mail server, fresh DB volume, exposed meta port)
- `docker-compose.s3.yml` — optional MinIO-backed storage override
- `volumes/db/` — Postgres init scripts, run once against an empty database:
  - `roles.sql`, `jwt.sql`, `webhooks.sql`, `logs.sql`, `pooler.sql`, `realtime.sql`, `_supabase.sql` — stock Supabase setup
  - `giftamizer/00NN-*.sql` — Giftamizer's application schema, run in numeric order (see below)
- `volumes/api/kong.yml` — API gateway routing
- `volumes/functions/` — Edge Functions (Deno)
- `dev/data.sql` — optional local dev seed data (empty by default)

## Updating production

`docker-entrypoint-initdb.d` scripts (everything under `volumes/db/`) only
run once, against a brand-new empty Postgres data directory — they will
**not** apply to the already-running production database. To ship a schema
change to production:

1. Write a new file, `volumes/db/giftamizer/00NN-description.sql`, describing the change.
2. Test it locally: reset your local stack (`./reset.sh`) and confirm the full script set applies cleanly, including your new file.
3. Apply the same SQL by hand to production (via the Studio SQL editor or `psql`).
4. Commit the new file. This keeps fresh installs (local dev, disaster recovery) in sync with what's actually live, since the numbered scripts are both the historical record and the fresh-install source of truth.

For non-schema changes (new image versions, compose config, etc.), edit
`docker-compose.yml` directly, test locally, then on the server run
`docker compose pull` followed by `docker compose up -d` for the affected
service(s).
