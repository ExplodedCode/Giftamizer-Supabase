# Giftamizer Production Deployment Guide

A generic, repeatable guide for deploying the Giftamizer backend
([Giftamizer-Supabase](https://github.com/ExplodedCode/Giftamizer-Supabase))
and frontend ([Giftamizer](https://github.com/ExplodedCode/Giftamizer)) to a
server via Docker Compose. Replace the placeholders below
(`<SERVER_USER>`, `<SERVER_IP>`, `<FRONTEND_DOMAIN>`, `<API_DOMAIN>`,
`<DOCKERHUB_NAMESPACE>`) with your own values.

## Topology

- **Frontend domain** (`<FRONTEND_DOMAIN>`, e.g. `app.example.com`) →
  forwarded by a reverse proxy to the frontend container's published port
  (`8081` in this guide).
- **Backend/API domain** (`<API_DOMAIN>`, e.g. `api.example.com`) →
  forwarded by the same reverse proxy to Kong's published port (`8000`).
- This guide assumes the server itself only serves plain HTTP, and TLS
  termination + public DNS are handled by a reverse proxy in front of it
  (could be on the same box or elsewhere — nginx, Caddy, Cloudflare Tunnel,
  etc.). Point that proxy's upstreams at the two ports above once DNS/proxy
  config is ready. If you don't have an external proxy and want this box to
  terminate TLS itself, add one (e.g. Caddy) in front of these two ports
  instead of exposing them directly.

## Directory layout

```
/giftamizer/
├── backend/    # git clone of ExplodedCode/Giftamizer-Supabase (Supabase stack)
│   ├── .env    # generated secrets + prod config, chmod 600, NOT in git
│   └── ...
└── frontend/
    └── docker-compose.yml   # runs the pre-built frontend image
```

`/giftamizer` is just a convention used here — pick any path, just stay
consistent between this doc and your actual install.

## Prerequisites

- Docker + Docker Compose v2 on the target server
- Docker Hub (or another registry) login on both your dev machine (to build
  and push the frontend image) and the server (to pull it), if you're
  building the frontend image elsewhere and shipping it as a prebuilt image
- A user with passwordless (or at least scriptable) `sudo` on the server,
  for creating `/giftamizer` and setting ownership

## Backend install

```bash
ssh <SERVER_USER>@<SERVER_IP>
sudo mkdir -p /giftamizer && sudo chown -R <SERVER_USER>:<SERVER_USER> /giftamizer
cd /giftamizer
git clone https://github.com/ExplodedCode/Giftamizer-Supabase.git backend
cd backend
cp .env.example .env
chmod 600 .env
```

Edit `.env`. At minimum, generate fresh secrets — **never ship a production
instance with the demo values from `.env.example`**:

| Variable | How to generate |
|---|---|
| `POSTGRES_PASSWORD` | `openssl rand -hex 24` (hex only — this value gets embedded in `postgres://` connection strings elsewhere in the compose file, so avoid `/`, `+`, `@` etc. that base64 could produce) |
| `JWT_SECRET` | `openssl rand -hex 32` |
| `ANON_KEY` / `SERVICE_ROLE_KEY` | derived from `JWT_SECRET` — run `./utils/generate-keys.sh` (or `.\utils\generate-keys.ps1`) and paste its output in |
| `DASHBOARD_USERNAME` / `DASHBOARD_PASSWORD` | pick a username; `openssl rand -hex 16` for the password |
| `SECRET_KEY_BASE` | `openssl rand -hex 64` |
| `VAULT_ENC_KEY` | `openssl rand -hex 16` (32+ chars required) |
| `PG_META_CRYPTO_KEY` | `openssl rand -hex 16` (32+ chars required) |
| `POOLER_TENANT_ID` | `openssl rand -hex 8` (just needs to be unique, not secret) |
| `RESTIC_PASSWORD` | `openssl rand -base64 32` — only needed if you're enabling offsite backup (see below), but cheap to generate now regardless |

Then set the app-facing config:

```
SITE_URL=https://<FRONTEND_DOMAIN>
ADDITIONAL_REDIRECT_URLS=https://<FRONTEND_DOMAIN>/**
API_EXTERNAL_URL=https://<API_DOMAIN>
SUPABASE_PUBLIC_URL=https://<API_DOMAIN>
COMPOSE_PROFILES=backup
```

(`COMPOSE_PROFILES=backup` turns on local pg_dump backups — see "Backups"
below for what else you can add here.)

**Watch out for:** the `db-backup` service's image tag
(`prodrigestivill/postgres-backup-local:<major>`) must match the major
version of the `db` service's Postgres image (currently 17). If a future
upstream bump moves `db` to Postgres 18 without also bumping `db-backup`'s
tag, `pg_dump` will refuse to run against a newer server and every backup
will silently fail — check `docker compose logs db-backup` after any
Postgres version bump to make sure backups are actually succeeding, not
just that the container is running.

Leave everything else (GitHub token, SMTP, S3, OAuth, etc.) at the
`.env.example` defaults unless you're using those features — see "Optional
extras" below.

### Starting the stack

```bash
cd /giftamizer/backend
chmod +x run.sh reset.sh utils/*.sh scripts/*.sh
./run.sh prod up                    # core stack + whatever's in COMPOSE_PROFILES
docker compose up -d urlmetadata    # see note below
```

**Why `urlmetadata` (if you want it) is started separately:** `urlmetadata`
and `smtp2graph` share the same `giftamizer-extras` Compose profile.
Activating `giftamizer-extras` in `COMPOSE_PROFILES` starts *both* — if you
want link-preview metadata (`urlmetadata`) but haven't set up an Azure AD
app registration for the email relay (`smtp2graph`), start `urlmetadata` by
naming it explicitly on the command line instead. Compose allows starting a
profiled service by name even when its profile isn't active in
`COMPOSE_PROFILES`; this creates and runs just that one service, and
`smtp2graph` is never created.

Consequence: a bare `docker compose up -d` (no service names) won't restart
`urlmetadata` if it's ever removed — always include it by name, or add
`giftamizer-extras` to `COMPOSE_PROFILES` once/if `smtp2graph` credentials
are added too (which will also start `smtp2graph`).

### Verifying

```bash
docker compose ps
# all services should show "healthy": studio, kong, auth, rest, realtime,
# storage, imgproxy, meta, functions, db, supavisor, plus db-backup/urlmetadata
# if you enabled them

curl -H "apikey: $(grep '^ANON_KEY=' .env | cut -d= -f2-)" http://localhost:8000/auth/v1/health
curl -H "apikey: $(grep '^ANON_KEY=' .env | cut -d= -f2-)" http://localhost:8000/rest/v1/
```

Studio dashboard: `http://<SERVER_IP>:8000/` (basic auth: `DASHBOARD_USERNAME`
/ `DASHBOARD_PASSWORD` from `.env`).

### Ports exposed on the host

| Port | Service | Notes |
|---|---|---|
| 8000 | Kong (API gateway / Studio) | forward `<API_DOMAIN>` here |
| 8443 | Kong (HTTPS) | only relevant if Kong itself terminates TLS |
| 5432 | Postgres (via Supavisor) | direct DB access |
| 6543 | Supavisor pooler (transaction mode) | |
| 5500 | urlmetadata | internal use by the app, if enabled |

5432/6543 are bound to all interfaces by default — nothing in the stock
compose file restricts them to localhost. If they're reachable from
somewhere they shouldn't be (e.g. the whole LAN, or the public internet),
firewall them (`ufw`, security group, etc.) to just the hosts that actually
need direct Postgres access; nothing in the stack itself needs them exposed
beyond the Docker network.

## Backups

### Local (`db-backup`)

- `prodrigestivill/postgres-backup-local:17` (match this to your `db`
  image's major version — see the callout above), enabled via the `backup`
  Compose profile
- Schedule: `BACKUP_SCHEDULE` (default `@daily`; also runs once on
  container start)
- Retention: `BACKUP_KEEP_DAYS` / `_WEEKS` / `_MONTHS` (defaults 7/4/6)
- Writes to `<install-dir>/backend/backups/{daily,weekly,monthly,last}`

Note: a raw host reboot (power loss, kernel panic, etc.) restarts containers
via Docker's own restart policy, not `docker compose up`, so `depends_on`
health-ordering isn't honored — `db-backup` may log one failed connection
attempt against `db` right after a crash/reboot before succeeding on its
next scheduled run. Harmless, but worth knowing so it doesn't look like a
real failure the first time you see it.

### Offsite (restic + rclone) — optional, recommended for production

1. Generate the rclone remote config:
   ```bash
   docker run --rm -it \
     -v /giftamizer/backend/volumes/rclone:/root/.config/rclone \
     mazzolino/restic:1.8.2 rclone config
   ```
   (or install `rclone` on the host directly and run `rclone config`)
2. In `.env`:
   ```
   RESTIC_PASSWORD=<generated above>
   RCLONE_REMOTE=<remote-name>:<bucket>/giftamizer
   ```
   **Do not lose `RESTIC_PASSWORD`** — it's the only way to decrypt any
   restic snapshot, local or offsite.
3. `COMPOSE_PROFILES=backup,restic-backup` (needs `backup` too, so there's
   something in `./backups` for restic to pick up)
4. `cd /giftamizer/backend && docker compose up -d restic-backup restic-prune`

Schedule defaults: nightly backup at 3:30am, prune at 4am, in whatever `TZ`
is set to (defaults to UTC if `TZ` isn't set in `.env`).

Restore procedure is documented in the backend repo's
[README.md](README.md#offsite-backup-optional-recommended-for-production)
under "Offsite backup" / "Restoring".

## Optional extras

### GitHub issue tracker (Support page)

1. Create a GitHub PAT (fine-grained or classic) with Issues read/write on
   the target repo.
2. Set `GITHUB_TOKEN`, `GITHUB_OWNER`, `GITHUB_REPO` in `.env`.
3. `docker compose up -d functions` (recreates just the edge-functions
   container to pick up the new env vars).

Leave `GITHUB_TOKEN` blank to disable — the frontend hides the Support nav
item automatically when it's unset.

### smtp2graph (SMTP → Microsoft Graph relay)

Needs an Azure AD app registration (`SMTP2GRAPH_CLIENT_ID` /
`SMTP2GRAPH_CLIENT_SECRET` / `SMTP2GRAPH_TENANT_ID` in `.env`) with
`Mail.Send` on a mailbox. Enable by adding `giftamizer-extras` to
`COMPOSE_PROFILES` (this also starts `urlmetadata` if it wasn't already
running — see the note above).

### Email / SMTP in general

If you don't configure real SMTP (or `smtp2graph`) at all,
`ENABLE_EMAIL_AUTOCONFIRM=true` (the `.env.example` default) means sign-up
still works without a confirmation click. Password-reset and invite emails
will simply fail to send until real SMTP credentials are in place.

## Frontend

### How the Dockerfile works

The frontend `Dockerfile` is a multi-stage build: a `node:20-alpine` stage
runs `npm ci && npm run build`, with `REACT_APP_SUPABASE_URL` /
`REACT_APP_SUPABASE_ANON_KEY` passed in via `--build-arg` and baked into the
JS bundle at build time (CRA inlines `REACT_APP_*` vars when it builds —
they can't be changed later at container-run time without rebuilding). The
final stage is `nginx:1.27-alpine`, serving the static build with an
SPA-fallback `nginx.conf` (`try_files $uri /index.html`, so client-side
routes don't 404 on refresh) and a `.dockerignore` that excludes
`node_modules`/`build`/`.git` from the build context. If your checkout of
the frontend repo doesn't have `Dockerfile` / `nginx.conf` / `.dockerignore`
set up this way, fix that before building — this doc assumes it's already
in place.

`REACT_APP_SUPABASE_ANON_KEY` here is Supabase's public **anon** key — it's
meant to be client-visible by design (protected by RLS on the backend, not
a secret), and ends up in the built JS bundle regardless of how it's passed
in.

### Build & push

From your dev machine (or CI), logged into your registry:

```bash
docker build \
  --build-arg REACT_APP_SUPABASE_URL=https://<API_DOMAIN> \
  --build-arg REACT_APP_SUPABASE_ANON_KEY=<ANON_KEY from backend/.env> \
  -t <DOCKERHUB_NAMESPACE>/giftamizer-frontend:latest .
docker push <DOCKERHUB_NAMESPACE>/giftamizer-frontend:latest
```

### Deploy on the server

`/giftamizer/frontend/docker-compose.yml`:

```yaml
services:
  frontend:
    image: <DOCKERHUB_NAMESPACE>/giftamizer-frontend:latest
    container_name: giftamizer-frontend
    restart: unless-stopped
    ports:
      - "8081:80"
```

```bash
cd /giftamizer/frontend
docker compose pull
docker compose up -d
```

Pick a host port other than `8080` if you might ever enable `smtp2graph`
(its default `SMTP2GRAPH_HTTP_PORT` is 8080) — `8081` avoids that
collision.

## Updating

**Backend** (non-schema changes — new image versions, compose config, etc.):
```bash
cd /giftamizer/backend
git pull
docker compose pull
docker compose up -d
docker compose up -d urlmetadata   # if you're using the explicit-start approach above
```
Schema changes ship as new `volumes/db/giftamizer/00NN-*.sql` files upstream
and must be applied to the running prod DB by hand (via Studio's SQL editor
or `psql`) — see the backend repo's README "Updating production" section.

**Frontend:** rebuild the image (see "Build & push" above) whenever the
frontend repo changes or the backend's public URL/keys change, push, then
on the server:
```bash
cd /giftamizer/frontend
docker compose pull
docker compose up -d
```

## Migrating data from another Giftamizer-Supabase instance

If you're standing up a new server to replace an existing one (version
upgrade, hardware move, etc.), here's the general approach for bringing
users/data/files over. Treat the old instance as **read-only** throughout —
everything below only ever reads from it.

### Diff the schemas first

Before copying anything, compare the old and new instances' schemas —
don't assume they match just because it's "the same app":

```bash
psql "postgresql://postgres:<password>@<OLD_HOST>:5432/postgres" -At -c "
select table_schema||'.'||table_name||'.'||column_name||':'||data_type||(case when is_nullable='NO' then ' NOT NULL' else '' end)
from information_schema.columns
where table_schema in ('public','auth','storage')
order by table_schema, table_name, ordinal_position;" > old_schema.txt

# same query against the new instance, then:
diff old_schema.txt new_schema.txt
```

In practice, the `public` (Giftamizer app) schema tends to be stable across
versions — the differences show up in `auth`/`storage`, which evolve with
the GoTrue/storage-api versions pinned in `docker-compose.yml`. Known
examples seen between older and current versions of this stack:

- `auth.identities`: older schemas have a `text` PK column named `id` (the
  provider's own identifier); newer ones rename that to `provider_id` and
  add a new surrogate `id uuid default gen_random_uuid()`. Map columns
  explicitly during import (`old.id` → `new.provider_id`) and let the new
  `id` auto-generate.
- `auth.users` gains columns over time (e.g. `is_anonymous`) — as long as
  they have defaults, a data-only copy that omits them is fine.
- `storage.buckets` gained `owner_id`/`type`, and older installs may have
  had buckets set `public=true` where a newer install's init scripts
  correctly default them to `public=false` (private, RLS-gated) — **don't
  overwrite the new instance's bucket rows** with the old ones; only import
  `storage.objects` (file metadata), and leave `storage.buckets` as the new
  install's init scripts created it.
- `storage.objects` may drop columns between versions (e.g. `level`) —
  exclude anything that doesn't exist in the target from your column list.
- Watch for buckets on the old instance that aren't part of the current
  app's bucket set (e.g. a leftover bucket used for static email-template
  assets) — these usually aren't user data and can be excluded.

### Copying the data

The general pattern: `COPY (SELECT ... explicit columns ...) TO stdout`
against the old instance (read-only), piped into `COPY <table> (...) FROM
stdin` against the new one, all wrapped in a single transaction with
`SET session_replication_role = replica`. This matters because the
`handle_new_user` trigger on `auth.users` auto-creates a profile + default
list on every insert — without disabling triggers, importing `auth.users`
would create duplicate profiles/lists alongside the real ones you're about
to import right after.

```sql
BEGIN;
SET session_replication_role = replica;
COPY auth.users (...) FROM stdin;
...
\.
COPY auth.identities (provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at) FROM stdin;
...
\.
COPY public.profiles FROM stdin;
...
\.
-- (repeat for groups, group_members, lists, lists_groups, items, items_lists,
--  items_status, notifications, external_invites, link_domains, system, user_roles)
COPY storage.objects (...) FROM stdin;
...
\.
SET session_replication_role = default;
COMMIT;
```

Run it against the new instance inside a single `psql` session (e.g.
`docker exec -i <db-container> psql -U postgres -v ON_ERROR_STOP=1 <
restore.sql`) so a bad statement rolls back the whole thing instead of
leaving a half-imported database — fix and re-run rather than trying to
patch a partial import.

After importing, verify: row counts match the source exactly, and there
are no orphaned foreign keys (`profiles`→`auth.users`, `group_members`→
`groups`, `items`→`profiles`, `storage.objects`→`storage.buckets`, etc.).

### Copying the storage files

Stream files directly between hosts rather than staging them locally:

```bash
ssh <OLD_HOST> "tar --xattrs --xattrs-include='*' -cf - -C <old-storage-path> avatars groups items lists" | \
ssh <NEW_HOST> "tar --xattrs --xattrs-include='*' -xf - -C <new-storage-path>"
```

**Critical:** always use `--xattrs --xattrs-include='*'` on both the
archive and extract side. Plain `tar` extracts the files fine but silently
drops the extended file attributes storage-api relies on — files copied
without `--xattrs` will 500 with `"The extended attribute does not exist"`
when fetched through the Storage API, even though they look present and
correct on disk. This applies to any file-level copy of the storage volume
(migrations, restic restores to a different host, etc.), not just this one
scenario.

Also confirm `GLOBAL_S3_BUCKET` and `STORAGE_TENANT_ID` in `.env` match
between old and new instances (or adjust the target path if they don't) —
the on-disk layout is `<storage-root>/<GLOBAL_S3_BUCKET>/<STORAGE_TENANT_ID>/<bucket>/<object name>/<version>`,
and changing either value without moving the files to match will break
every existing file reference.

After copying, spot-check a random sample of `storage.objects` rows through
the actual Storage API (not just checking the files exist on disk) — the
real object path includes the `version` column
(`<bucket>/<object name>` maps internally to
`<bucket>/<object name>/<version>` on disk), so a naive path check without
`version` will report false negatives.

### Known caveat: legacy password hash formats

If the old instance ever ran a third-party auth-migration middleware (e.g.
a Firebase-to-Supabase migration proxy), some `encrypted_password` values
may be in that middleware's custom format rather than standard bcrypt.
Those rows will copy over fine, but GoTrue's standard bcrypt verification
won't recognize them — affected users won't be able to log in with their
existing password and will need to use "forgot password" once real SMTP is
configured. Users who signed up normally (bcrypt hashes) are unaffected.
Worth checking for before assuming a 100% successful login rate post-migration.

## Post-deployment checklist

- [ ] Point your reverse proxy at the server's frontend/backend ports for
      `<FRONTEND_DOMAIN>` / `<API_DOMAIN>`, with TLS terminated there (or on
      this box, if you added a local reverse proxy).
- [ ] If replacing an existing production instance, cut over DNS only once
      you've verified the new instance end-to-end.
- [ ] Set up offsite backup (`rclone config` + `restic-backup` profile) if
      you haven't already.
- [ ] Add a `GITHUB_TOKEN` if you want the Support page's issue tracker.
- [ ] Add real SMTP (or `smtp2graph` + Azure AD creds) before relying on
      password-reset/invite emails, or before migrated users with legacy
      password hashes need to recover access.
- [ ] Consider firewalling ports 5432/6543 (direct Postgres) to just the
      hosts that actually need them.

## Updating environment variables after deployment

General procedure for changing anything in `backend/.env` once the stack is
already running:

1. Edit `/giftamizer/backend/.env`.
2. `cd /giftamizer/backend && docker compose up -d` — Compose diffs each
   service's resolved config against what's running and recreates any
   container whose environment actually changed; services with no relevant
   change are left alone (no unnecessary restarts).
3. If a service was started outside the normal profile flow (like
   `urlmetadata` above), you may need to name it explicitly:
   `docker compose up -d urlmetadata`.
4. To force a specific service to pick up a change you're not sure Compose
   noticed, add `--force-recreate`: `docker compose up -d --force-recreate <service>`.
5. Verify with `docker compose ps` and `docker compose logs <service>`.

A few variables need more than a routine restart:

- **`JWT_SECRET` / `ANON_KEY` / `SERVICE_ROLE_KEY`** — changing these
  invalidates every existing user session immediately (all previously
  issued JWTs stop validating). The frontend also has `ANON_KEY` baked into
  its build (see below), so rotating these requires rebuilding, pushing,
  and redeploying the frontend too, not just restarting the backend.
- **`REACT_APP_*` frontend variables** (`REACT_APP_SUPABASE_URL`,
  `REACT_APP_SUPABASE_ANON_KEY`) — these are **not** read from
  `backend/.env` at all; they're compiled into the frontend's JS bundle at
  Docker build time (see "How the Dockerfile works" above). Editing
  `backend/.env` has zero effect on the frontend. To change them, rebuild
  the frontend image with new `--build-arg` values, push, and redeploy
  (`docker compose pull && docker compose up -d` in `/giftamizer/frontend`).
- **`COMPOSE_PROFILES`** — adding a profile doesn't retroactively touch
  services outside it, and *removing* a profile from this variable doesn't
  stop the now-out-of-scope container either; `docker compose up -d` only
  reconciles what's currently in scope. To actually stop a service you just
  removed from `COMPOSE_PROFILES`, stop it explicitly:
  `docker compose stop <service>`. Remember the `urlmetadata`/`smtp2graph`
  shared-profile quirk described earlier if you touch `giftamizer-extras`.
- **`KONG_HTTP_PORT` / `KONG_HTTPS_PORT`** (or any other host-port
  variable) — `docker compose up -d` will recreate the container with the
  new port binding, but you'll also need to update any reverse proxy
  pointing at the old port, and this causes a brief outage for that service
  while it recreates.
- **`GLOBAL_S3_BUCKET` / `STORAGE_TENANT_ID`** — these determine the
  on-disk path under `volumes/storage` for every stored file (see the
  migration section above). Changing either after the instance already has
  uploaded files will make storage-api look in the wrong place for
  everything that was already uploaded; don't change these post-install
  without also relocating the files to match the new path.
- **`POSTGRES_PASSWORD`** — changing this in `.env` alone does *not* change
  the actual Postgres role's password inside the running database; you'd
  need to change it in both places (`ALTER ROLE postgres WITH PASSWORD
  '...'` in Postgres, and the new value in `.env`) and recreate every
  service that connects to the database, or you'll get authentication
  failures.

After any secret rotation, double-check `chmod 600 .env` is still in effect
— some editors/tools reset file permissions on save.
