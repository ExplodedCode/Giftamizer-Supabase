# Giftamizer Supabase Backend

This repo is the self-hosted [Supabase](https://supabase.com) backend for
[Giftamizer](https://giftamizer.com) — Postgres, Auth, Storage, Realtime,
Edge Functions, and a handful of Giftamizer-specific services, all run via
Docker Compose. It's based on the official
[Supabase self-hosting Docker guide](https://supabase.com/docs/guides/self-hosting/docker).

## Prerequisites

- Docker and Docker Compose v2 (on Windows: Docker Desktop with the WSL2 backend)
- Git

Every script in this repo ships as both a `.sh` (macOS/Linux/Git Bash) and a
`.ps1` (native Windows PowerShell) file — pick whichever matches your shell.
No WSL or Git Bash is required on Windows. If PowerShell blocks the scripts
with an execution-policy error, run once per shell session:
`Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass`.

## Local development quick start

```sh
cp .env.example .env
./run.sh dev up
# equivalent to: docker compose -f docker-compose.yml -f ./dev/docker-compose.dev.yml up -d
```

On Windows PowerShell:

```powershell
Copy-Item .env.example .env
.\run.ps1 dev up
```

`run.sh`/`run.ps1` is a thin wrapper — `dev {up|down|restart|logs [service]|ps}` and
`prod {up|down|restart|logs [service]|ps}` — so you don't have to
remember the multi-file flags. Everything it does works exactly the same as
calling `docker compose` directly if you'd rather do that.

If you want your own JWT secret/keys instead of the shared demo ones in
`.env.example` (recommended for anything beyond a throwaway local instance),
run `./utils/generate-keys.sh` (or `.\utils\generate-keys.ps1` on Windows) and
paste the output into your `.env`.

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
# or on Windows: .\reset.ps1
```

### Giftamizer's extra services (optional)

Production also runs three Giftamizer-specific containers: `smtp2graph`
(SMTP-to-Microsoft-Graph email relay), `urlmetadata` (link preview
metadata), and `firebase-auth-middleware` (legacy Firebase password
verification). These are **not** started by default locally since they need
Azure AD / Firebase credentials. To opt in:

```sh
echo "COMPOSE_PROFILES=giftamizer-extras" >> .env
./run.sh dev up
```

On Windows PowerShell: `Add-Content .env "COMPOSE_PROFILES=giftamizer-extras"`, then `.\run.ps1 dev up`.

### S3-backed storage (optional)

To test with S3-compatible storage (MinIO) instead of the local filesystem:

```sh
docker compose -f docker-compose.yml -f docker-compose.s3.yml up -d
```

### Automated backups (optional, always-on in production)

A `db-backup` service (`prodrigestivill/postgres-backup-local`) takes scheduled
`pg_dump` backups with daily/weekly/monthly rotation into `./backups/`
(gitignored). It's opt-in via the `backup` Compose profile:

```sh
echo "COMPOSE_PROFILES=giftamizer-extras,backup" >> .env
```

On Windows PowerShell: `Add-Content .env "COMPOSE_PROFILES=giftamizer-extras,backup"`.

Tune the schedule/retention via `BACKUP_SCHEDULE`, `BACKUP_KEEP_DAYS`,
`BACKUP_KEEP_WEEKS`, `BACKUP_KEEP_MONTHS` in `.env` (see `.env.example`).

## Repo layout

- `docker-compose.yml` — the full stack; this is also what production runs
- `dev/docker-compose.dev.yml` — local dev overrides (fake mail server, fresh DB volume, exposed meta port)
- `docker-compose.s3.yml` — optional MinIO-backed storage override
- `run.sh` / `run.ps1` — convenience wrapper for the common `docker compose` invocations above
- `reset.sh` / `reset.ps1` — wipes containers/volumes/`.env` and starts over
- `utils/generate-keys.sh` / `utils/generate-keys.ps1` — generates a fresh `JWT_SECRET`/`ANON_KEY`/`SERVICE_ROLE_KEY` set
- `scripts/check-schema-drift.sh` / `scripts/check-schema-drift.ps1` — diffs a fresh local install's schema against a live database (see below)
- `volumes/db/` — Postgres init scripts, run once against an empty database:
  - `roles.sql`, `jwt.sql`, `webhooks.sql`, `logs.sql`, `pooler.sql`, `realtime.sql`, `_supabase.sql` — stock Supabase setup
  - `giftamizer/00NN-*.sql` — Giftamizer's application schema, run in numeric order (see below)
- `volumes/api/kong.yml` — API gateway routing
- `volumes/functions/` — Edge Functions (Deno)
- `dev/data.sql` — optional local dev seed data (empty by default)
- `backups/` — gitignored; where the optional `db-backup` service writes to

## Updating production

`docker-entrypoint-initdb.d` scripts (everything under `volumes/db/`) only
run once, against a brand-new empty Postgres data directory — they will
**not** apply to the already-running production database. To ship a schema
change to production:

1. Write a new file, `volumes/db/giftamizer/00NN-description.sql`, describing the change.
2. Test it locally: reset your local stack (`./reset.sh` / `.\reset.ps1`) and confirm the full script set applies cleanly, including your new file.
3. Apply the same SQL by hand to production (via the Studio SQL editor or `psql`).
4. Commit the new file. This keeps fresh installs (local dev, disaster recovery) in sync with what's actually live, since the numbered scripts are both the historical record and the fresh-install source of truth.
5. Periodically (or after any change you're unsure got fully captured), run
   `./scripts/check-schema-drift.sh "postgres://...prod-connection-string..."`
   (or `.\scripts\check-schema-drift.ps1 "postgres://..."` on Windows)
   to diff prod's actual schema against what a fresh local install produces —
   this is exactly the kind of drift that prompted this doc.

For non-schema changes (new image versions, compose config, etc.), edit
`docker-compose.yml` directly, test locally, then on the server run
`docker compose pull` followed by `docker compose up -d` for the affected
service(s).
