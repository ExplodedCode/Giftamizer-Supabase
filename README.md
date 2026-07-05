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

**Upgrading an existing install:** this repo tracks upstream
[supabase/supabase](https://github.com/supabase/supabase)'s `docker-compose.yml`.
Postgres 17 is now the default `db` image — an *existing* Postgres 15 data
volume won't start on it as-is; run `sudo bash utils/upgrade-pg17.sh` first
(see the script's header for details), or pin `docker-compose.pg15.yml` to
keep running 15 for now. New installs need nothing extra. Either way, add
`PG_META_CRYPTO_KEY` to your `.env` (Studio/postgres-meta now require it) —
see `.env.example` for the format.

This starts the full Supabase stack plus dev conveniences:

- **Studio / API gateway** — http://localhost:8000 (basic auth: `DASHBOARD_USERNAME` / `DASHBOARD_PASSWORD` from `.env`). Every route other than Studio's own catch-all (`/auth/v1`, `/rest/v1`, `/storage/v1`, etc.) is proxied through Kong here — this repo doesn't serve the Giftamizer app itself.
- **Inbucket (fake mail server)** — http://localhost:9000, catches all auth emails so you don't need real SMTP locally
- **Postgres Meta** — exposed on `localhost:5555` for direct DB introspection tools

The Giftamizer frontend is a separate repo/process — see its
[local-setup docs](https://github.com/ExplodedCode/Giftamizer/blob/main/docs/local-setup.md)
for running it (CRA dev server on http://localhost:3001, talking to this
backend's port 8000 over CORS).

The Giftamizer schema (`profiles`, `groups`, `items`, `lists`, RLS policies,
storage buckets, etc.) is created automatically from
`volumes/db/giftamizer/*.sql` the first time the `db` container initializes
an empty data directory. Sign up through the app (or Studio's Auth panel) to
create a user — the `handle_new_user` trigger sets up their profile and
default list automatically.

### Seeding test data

Once the dev stack is up, `dev/seed-test-data.js` populates it with 5 users,
2 groups, and 30 items (all through the real Auth/REST/Storage APIs, so RLS
and triggers behave exactly as they would for a real signup) — useful for
exercising the app without clicking through signup forms by hand:

```sh
node dev/seed-test-data.js
```

3 of the 5 users have `enable_lists` on; of those, one gets a second list,
another gets a third, and the third gets two child lists (`child_list: true`,
e.g. wishlists managed on behalf of their kids) - all on top of everyone's
auto-created default list. Every non-default list is published to both
groups via `lists_groups` so it shows up as a separate list within a group.
About 70% of items, groups, non-default lists, and user avatars get a real
downloaded image from
[picsum.photos](https://picsum.photos) uploaded to Storage. All seeded users
share the password `Password123!`. Requires Node 18+ and a fresh database —
re-running against already-seeded data will fail on duplicate emails; reset
first (`./reset.sh` / `.\reset.ps1`) if you need to start over.

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

Production also runs two Giftamizer-specific containers: `smtp2graph`
(SMTP-to-Microsoft-Graph email relay) and `urlmetadata` (link preview
metadata). These are **not** started by default locally since they need
Azure AD credentials. To opt in:

```sh
echo "COMPOSE_PROFILES=giftamizer-extras" >> .env
./run.sh dev up
```

On Windows PowerShell: `Add-Content .env "COMPOSE_PROFILES=giftamizer-extras"`, then `.\run.ps1 dev up`.

### GitHub issue tracker (optional)

The Support page's issue tracker is powered by the `github` edge function.
Set `GITHUB_TOKEN`, `GITHUB_OWNER`, and `GITHUB_REPO` in `.env` to enable it —
leave `GITHUB_TOKEN` blank to disable; the frontend hides the Support nav
item when it isn't configured.

### S3-backed storage (optional)

To test with S3-compatible storage (MinIO) instead of the local filesystem:

```sh
docker compose -f docker-compose.yml -f docker-compose.s3.yml up -d
```

### Logs / Analytics dashboard (optional)

Studio's Logs page needs Logflare + Vector, which aren't started by default
(matches upstream). To enable:

```sh
echo "LOGFLARE_PUBLIC_ACCESS_TOKEN=$(openssl rand -base64 24)" >> .env
echo "LOGFLARE_PRIVATE_ACCESS_TOKEN=$(openssl rand -base64 24)" >> .env
docker compose -f docker-compose.yml -f docker-compose.logs.yml up -d
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

### Offsite backup (optional, recommended for production)

`db-backup` above only protects against DB-level mistakes/corruption - the
dumps still live on the same disk as everything else, and nothing backs up
the Storage files in `./volumes/storage` at all. Two `mazzolino/restic`-based
services close both gaps, using a two-stage approach: **restic** first takes
encrypted, deduplicated snapshots of `./backups` (the pg_dumps) and
`./volumes/storage` (uploaded files) into a local repository
(`./volumes/restic-repo`), then **rclone** mirrors that local repository to
whichever remote you've configured - Backblaze B2, Cloudflare R2, AWS S3,
SFTP, Google Drive, or any of the ~70 other backends rclone supports. Nothing
about the remote is hardcoded; you define it yourself via `rclone config`.

- `restic-backup` — runs the restic backup + forget on `RESTIC_BACKUP_CRON`, then syncs to the remote on success.
- `restic-prune` — runs `restic prune` on `RESTIC_PRUNE_CRON` to actually reclaim space forget only marked as removable, then syncs again (so deleted snapshots disappear remotely too, not just locally).

Both are opt-in via the `restic-backup` Compose profile, and only useful
alongside `backup` (so there's something in `./backups` for restic to pick up):

```sh
echo "COMPOSE_PROFILES=giftamizer-extras,backup,restic-backup" >> .env
```

On Windows PowerShell: `Add-Content .env "COMPOSE_PROFILES=giftamizer-extras,backup,restic-backup"`.

Before starting them:

1. Create `./volumes/rclone/rclone.conf` by running `rclone config` and following the prompts for whichever backend you're using. If you don't have `rclone` installed locally, run it via the same image instead:
   ```sh
   docker run --rm -it -v "$(pwd)/volumes/rclone:/root/.config/rclone" mazzolino/restic:1.8.2 rclone config
   ```
2. In `.env` (see `.env.example` for the full list):
   - `RESTIC_PASSWORD` — encrypts the local repository. Generate with `openssl rand -base64 32` and **do not lose it** — without it, the backups (local or offsite) are unrecoverable.
   - `RCLONE_REMOTE` — the remote name/path from step 1, e.g. `b2:my-bucket-name/giftamizer` or `r2:my-bucket-name/giftamizer`.

Schedule/retention (`RESTIC_BACKUP_CRON`, `RESTIC_PRUNE_CRON`,
`RESTIC_KEEP_DAYS/WEEKS/MONTHS`) default to a nightly backup at 3:30am and
prune at 4am, keeping 7 daily/4 weekly/6 monthly snapshots - tune in `.env`
if needed.

**Restoring:** if the host and `./volumes/restic-repo` are still intact, restore directly from the local repo:

```sh
docker run --rm -it \
  -e RESTIC_REPOSITORY=/data/restic-repo -e RESTIC_PASSWORD=<your-password> \
  -v "$(pwd)/volumes/restic-repo:/data/restic-repo" \
  -v "$(pwd)/restore:/restore" \
  mazzolino/restic:1.8.2 restic restore latest --target /restore
```

If the host itself was lost, pull the repository back down from the remote first:

```sh
docker run --rm -it \
  -v "$(pwd)/volumes/rclone:/root/.config/rclone" \
  -v "$(pwd)/volumes/restic-repo:/data/restic-repo" \
  mazzolino/restic:1.8.2 rclone sync "<RCLONE_REMOTE value>" /data/restic-repo
```

then run the `restic restore` command above. Either way this pulls the
latest snapshot's `./backups` and `./volumes/storage` contents into
`./restore/data/...` on the host - from there, restore the Postgres dump
with `psql`/`pg_restore` and copy the storage files back into
`./volumes/storage` (stop the `storage`/`imgproxy` containers first).
`restic snapshots` lists available snapshots if you need an earlier point
in time instead of `latest`.

## Repo layout

- `docker-compose.yml` — the full stack; this is also what production runs
- `dev/docker-compose.dev.yml` — local dev overrides (fake mail server, fresh DB volume, exposed meta port)
- `docker-compose.pg15.yml` / `docker-compose.pg17.yml` — pin the `db` image to Postgres 15 (existing un-upgraded installs) or 17 (explicit default) instead of whatever `docker-compose.yml` currently ships
- `docker-compose.logs.yml` — optional Logflare + Vector override, powers Studio's Logs page
- `docker-compose.s3.yml` — optional MinIO-backed storage override
- `run.sh` / `run.ps1` — convenience wrapper for the common `docker compose` invocations above
- `reset.sh` / `reset.ps1` — wipes containers/volumes/`.env` and starts over
- `utils/generate-keys.sh` / `utils/generate-keys.ps1` — generates a fresh `JWT_SECRET`/`ANON_KEY`/`SERVICE_ROLE_KEY` set
- `utils/upgrade-pg17.sh` — in-place Postgres 15 → 17 data upgrade for existing installs (bash-only; see its header)
- `scripts/check-schema-drift.sh` / `scripts/check-schema-drift.ps1` — diffs a fresh local install's schema against a live database (see below)
- `volumes/db/` — Postgres init scripts, run once against an empty database:
  - `roles.sql`, `jwt.sql`, `webhooks.sql`, `logs.sql`, `pooler.sql`, `realtime.sql`, `_supabase.sql` — stock Supabase setup
  - `giftamizer/00NN-*.sql` — Giftamizer's application schema, run in numeric order (see below)
- `volumes/api/kong.yml` — API gateway routing
- `volumes/api/kong-entrypoint.sh` — Kong's custom entrypoint (env substitution + opaque-key Lua expressions)
- `volumes/functions/` — Edge Functions (Deno)
- `volumes/logs/vector.yml` — Vector log-routing config, used by `docker-compose.logs.yml`
- `dev/data.sql` — optional local dev seed data (empty by default)
- `dev/seed-test-data.js` — populates a running dev stack with sample users/groups/items via the real Auth/REST/Storage APIs (see above)
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
