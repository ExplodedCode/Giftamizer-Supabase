# Backups

How Giftamizer's backend is backed up, how to configure it, and the commands
for checking status, listing backups, taking a manual backup and restoring.

All commands run on the server, from the backend install directory:

```bash
cd /giftamizer/backend
```

- [How it works](#how-it-works)
- [What is (and isn't) backed up](#what-is-and-isnt-backed-up)
- [Configuration](#configuration)
- [Status](#status)
- [Listing backups](#listing-backups)
- [Manual backup](#manual-backup)
- [Restore](#restore)
- [Troubleshooting](#troubleshooting)

## How it works

Two layers, both opt-in through Docker Compose profiles (`COMPOSE_PROFILES` in
`.env`). Production should run both: `COMPOSE_PROFILES=backup,restic-backup`.

```
 db ──pg_dump──▶ ./backups/{daily,weekly,monthly,last}      (local, 00:00 UTC)
                       │
                       ▼
 ./backups  +  ./volumes/storage ──restic──▶ ./volumes/restic-repo   (local repo, encrypted)
                                                    │
                                                    └──rclone sync──▶ your remote (offsite)
```

### Layer 1 - local database dumps (`db-backup`)

| | |
|---|---|
| Container | `supabase-db-backup` (`prodrigestivill/postgres-backup-local:17`) |
| Profile | `backup` |
| What | A plain-SQL `pg_dump`, gzipped, of the whole `postgres` database (all schemas: `public`, `auth`, `storage`, ...). No roles are included - Supabase's own roles come from the `db` image. |
| When | `BACKUP_SCHEDULE` (default `@daily` = 00:00 **UTC**; the container does not use `TZ`). Also once every time the container starts (`BACKUP_ON_START`). |
| Where | `./backups/` |
| Retention | `BACKUP_KEEP_DAYS` / `_WEEKS` / `_MONTHS` (default 7 / 4 / 6) |

Layout of `./backups`:

```
backups/
  last/     postgres-YYYYMMDD-HHMMSS.sql.gz   newest dump (+ postgres-latest.sql.gz symlink)
  daily/    postgres-YYYYMMDD.sql.gz          one per day, last 7
  weekly/   postgres-YYYYWW.sql.gz            one per ISO week, last 4
  monthly/  postgres-YYYYMM.sql.gz            one per month, last 6
```

The image tag's major version **must match the `db` image's Postgres major
version** (currently 17). If they differ, `pg_dump` refuses to run and every
backup silently fails - check [Status](#status) after any Postgres upgrade.

On its own this layer protects against bad migrations, deleted rows and
corruption. It does **not** protect against losing the server or its disk (the
dumps live on the same disk) and it does **not** include uploaded files.

### Layer 2 - restic + offsite sync (`restic-backup`, `restic-prune`)

| | |
|---|---|
| Containers | `supabase-restic-backup`, `supabase-restic-prune` (`mazzolino/restic:1.8.2`) |
| Profile | `restic-backup` (also enable `backup`, so `./backups` has something to read) |
| What | Encrypted, deduplicated restic snapshots of `./backups` (the dumps) **and** `./volumes/storage` (uploaded images/avatars), tagged `giftamizer` |
| Local repo | `./volumes/restic-repo` (encrypted with `RESTIC_PASSWORD`) |
| Offsite | After every successful backup/prune, `scripts/restic-offsite-sync.sh` mirrors the local repo to `RCLONE_REMOTE` with `rclone sync` - any rclone backend (B2, R2, S3, SFTP, ...). It tries 3 times a minute apart, and refuses to sync if the remote holds a *different* restic repository (so a freshly initialised repo can't wipe the offsite snapshots). |
| Health | `supabase-restic-backup` is `unhealthy` when the last successful backup + sync is older than `RESTIC_HEALTH_MAX_AGE_MINUTES` (default 26 h). Docker only shows this; nothing sends an alert. |
| When | `RESTIC_BACKUP_CRON` (default `0 30 3 * * *`, 03:30) and `RESTIC_PRUNE_CRON` (default `0 0 4 * * *`, 04:00), in the `TZ` set in `.env` (UTC if unset). Also once on container start. |
| Retention | `RESTIC_KEEP_DAYS` / `_WEEKS` / `_MONTHS` (default 7 / 4 / 6 snapshots) |

`restic-backup` takes the snapshot, then runs `forget` (marks old snapshots as
removable) and syncs. `restic-prune` runs `prune` (actually frees the space) and
syncs again so deleted snapshots also disappear from the remote. They are two
containers because the image allows only one cron job per container.

Because the snapshot runs after the 00:00 UTC dump, each night's snapshot
contains that night's dump plus the files as they were at 03:30.

## What is (and isn't) backed up

| Item | Backed up? |
|---|---|
| Database (all schemas, incl. auth users) | Yes - dumps, local + offsite |
| Uploaded files (`./volumes/storage`) | Yes - offsite layer only |
| `.env` (JWT secret, API keys, SMTP, `RESTIC_PASSWORD`, ...) | **No** |
| `./volumes/rclone/rclone.conf` (remote credentials) | **No** |
| Raw Postgres data directory | No (the dumps are the backup) |
| Postgres roles / globals | No (recreated by the `db` image) |
| Code, SQL migrations, edge functions | In git |

**Keep copies of `.env`, `RESTIC_PASSWORD` and `rclone.conf` somewhere that is
not this server** (a password manager). Without `RESTIC_PASSWORD` no snapshot
can be decrypted, and without the same `JWT_SECRET`/API keys from `.env`, a
restored stack won't accept existing sessions or match the built frontend.

## Configuration

### Local dumps

In `.env`:

```
COMPOSE_PROFILES=backup
BACKUP_SCHEDULE=@daily     # cron syntax also works, e.g. "0 2 * * *"
BACKUP_KEEP_DAYS=7
BACKUP_KEEP_WEEKS=4
BACKUP_KEEP_MONTHS=6
```

Apply changes with `docker compose up -d db-backup`.

### Offsite

1. **Create the rclone remote.** The image's default entrypoint ignores
   commands, so override it with `--entrypoint rclone`:

   ```bash
   mkdir -p volumes/rclone
   docker run --rm -it --entrypoint rclone \
     -v "$(pwd)/volumes/rclone:/root/.config/rclone" \
     mazzolino/restic:1.8.2 config
   ```

   Use a bucket-scoped key. Backends that log in with the account password
   (MEGA) can't be scoped: anyone who reads `rclone.conf` can delete everything
   in that account, so give it an account used for nothing else. Avoid backends that need a browser sign-in
   (Google Drive, OneDrive) on a headless server. This writes
   `volumes/rclone/rclone.conf` (root-owned, mode 600, gitignored).

2. **Set `.env`**, adding to the existing profiles rather than replacing them:

   ```
   COMPOSE_PROFILES=backup,restic-backup
   RESTIC_PASSWORD=<openssl rand -base64 32>
   RCLONE_REMOTE=<remote-name>:<bucket-or-path>/giftamizer
   TZ=America/New_York                # optional; moves the restic cron times
   # optional overrides:
   # RESTIC_BACKUP_CRON=0 30 3 * * *  (6 fields, seconds first)
   # RESTIC_PRUNE_CRON=0 0 4 * * *
   # RESTIC_KEEP_DAYS=7  RESTIC_KEEP_WEEKS=4  RESTIC_KEEP_MONTHS=6
   ```

   **Do not lose `RESTIC_PASSWORD`**, and don't change it after the repository
   exists - it can't re-encrypt existing snapshots.

3. **Start only the two new containers** (avoids recreating the rest of the stack):

   ```bash
   docker compose up -d restic-backup restic-prune
   ```

   The first run starts immediately: it initialises the repository, takes the
   first snapshot and uploads it. Check it with [Status](#status).

## Status

### Quick check

```bash
# Containers up and healthy?
docker ps -a --format 'table {{.Names}}\t{{.Status}}' | grep -E 'NAMES|backup|restic'

# Is the newest dump recent? (should be < 25 hours old)
newest=$(ls -1t backups/last/postgres-2*.sql.gz | head -1)
echo "$newest  $(( ($(date +%s) - $(stat -c %Y "$newest")) / 3600 ))h old  $(du -h "$newest" | cut -f1)"

# Did the last dump succeed?
docker logs --tail 3 supabase-db-backup

# Did the last restic backup + offsite sync succeed? (look for "Backup successful")
docker logs --tail 40 supabase-restic-backup
docker logs --tail 15 supabase-restic-prune
```

Healthy output: `supabase-db-backup` and `supabase-restic-backup` both
`(healthy)`, the last `db-backup` log line
is `SQL backup created successfully`, and the `restic-backup` log has
`Backup successful` followed by `offsite-sync: synced to ...`, dated last night.

### Helper functions for restic and rclone

The restic repo and rclone config are only reachable through the container
image, so define these two shell functions once per session. Every command
below that starts with `restic` or `rcl` uses them:

```bash
restic() {
  docker run --rm \
    -e RESTIC_REPOSITORY=/data/restic-repo \
    -e RESTIC_PASSWORD="$(grep ^RESTIC_PASSWORD= .env | cut -d= -f2-)" \
    -v "$PWD/volumes/restic-repo:/data/restic-repo" \
    mazzolino/restic:1.8.2 "$@"      # restic args only - no leading "restic"
}
rcl() {
  docker run --rm --entrypoint rclone \
    -v "$PWD/volumes/rclone:/root/.config/rclone" \
    mazzolino/restic:1.8.2 "$@"
}
REMOTE="$(grep ^RCLONE_REMOTE= .env | cut -d= -f2-)"
```

### Repository health and sizes

```bash
restic snapshots                      # newest should be from last night
restic stats                          # logical size of the latest snapshot
restic check                          # verifies repository structure (read-only)
restic check --read-data-subset=10%   # also re-reads a 10% sample of the data
rcl size "$REMOTE"                    # objects/size actually held offsite
```

The offsite size should be roughly the local repo's size. To confirm the remote
is an exact copy of the local repo (read-only):

```bash
docker run --rm --entrypoint rclone \
  -v "$PWD/volumes/rclone:/root/.config/rclone" \
  -v "$PWD/volumes/restic-repo:/data/restic-repo:ro" \
  mazzolino/restic:1.8.2 check /data/restic-repo "$REMOTE" --one-way
```

## Listing backups

### Local dumps

```bash
ls -lh backups/last backups/daily backups/weekly backups/monthly
du -sh backups
```

### Local restic repository

```bash
restic snapshots                      # all snapshots (ID, time, tag, paths, size)
restic snapshots --latest 1
restic ls latest --long | head -50    # files inside the latest snapshot
restic ls <snapshot-id> /data/backups # dumps captured in a given snapshot
```

### Offsite

The remote holds the restic repository's encrypted files, not readable
backups, so "listing offsite backups" means listing the snapshots in that copy.
Pull-free options:

```bash
rcl lsd "$REMOTE"                     # repo folders: data, index, keys, locks, snapshots
rcl ls  "$REMOTE/snapshots"           # one small file per snapshot
rcl size "$REMOTE"
```

To see snapshots *as stored offsite* (rather than the local copy), point restic
at the remote directly. This works from any machine that has the rclone config
and `RESTIC_PASSWORD`, so it doubles as a check that offsite recovery is
possible without the local repo:

```bash
docker run --rm --entrypoint sh \
  -v "$PWD/volumes/rclone:/root/.config/rclone" \
  -e RESTIC_PASSWORD="$(grep ^RESTIC_PASSWORD= .env | cut -d= -f2-)" \
  mazzolino/restic:1.8.2 -c "restic -r rclone:$REMOTE snapshots"
```

A `locks: error listing: directory not found` line from rclone is harmless
(the lock folder is empty). restic takes a brief lock on the remote while it
reads, so don't run this at the same moment as a scheduled backup.

## Manual backup

### Database dump now

```bash
docker exec supabase-db-backup /backup.sh
ls -lh backups/last
```

This runs the same job as the schedule. It replaces *today's* daily dump (and
the weekly/monthly one for the current period) with the fresh one, and refreshes
`last/`.

A throwaway dump to a file of your choice, independent of the rotation:

```bash
docker exec supabase-db pg_dump -U postgres postgres | gzip > ~/manual-$(date +%Y%m%d-%H%M%S).sql.gz
```

### Offsite snapshot now (dumps + storage files)

Take a fresh dump first so the snapshot contains it, then restart the restic
container - it runs a full backup, `forget` and offsite sync on startup:

```bash
docker exec supabase-db-backup /backup.sh
docker compose restart restic-backup
docker logs -f supabase-restic-backup      # Ctrl+C when you see "Backup successful"
restic snapshots                           # confirm the new snapshot (needs the helper functions)
```

To also reclaim space and re-sync: `docker compose restart restic-prune`.

### Before risky changes (migrations, upgrades)

Dumps don't include storage files, so take both:

```bash
docker exec supabase-db-backup /backup.sh
tar czf ~/storage-$(date +%Y%m%d).tgz volumes/storage
cp backups/last/postgres-2*.sql.gz ~/        # then copy both files off the server
```

## Restore

> Practise a restore before you need one. Pulling from offsite and step A were
> rehearsed on 2026-11-25: every table matched the dump's row counts, and every
> restored file that still existed live was identical. Step D (a full stack on a
> new host) has not been rehearsed.

### Get the backup files

**From the local dumps** (server and disk intact): use `backups/last/` /
`daily/` / `weekly/` / `monthly/` directly.

**From offsite** (host lost, or the local repo is damaged): use
`scripts/pull-offsite-backup.sh`. It pulls the repo from the remote, restores a
snapshot and writes one archive containing the dump and the storage files:

```bash
bash scripts/pull-offsite-backup.sh              # latest snapshot -> ~/giftamizer-backup-<timestamp>.tar.gz
bash scripts/pull-offsite-backup.sh <snapshot-id> /some/dir
```

Needs `.env` (`RCLONE_REMOTE`, `RESTIC_PASSWORD`) and `volumes/rclone/rclone.conf`
in place. On a brand-new host, recreate those from your off-server copies
first. Unpack with `tar -xzf giftamizer-backup-*.tar.gz` (gives `database/` and
`storage/`).

Manual equivalent, from the local repo:

```bash
mkdir -p ~/restore
docker run --rm -e RESTIC_REPOSITORY=/data/restic-repo \
  -e RESTIC_PASSWORD="$(grep ^RESTIC_PASSWORD= .env | cut -d= -f2-)" \
  -v "$PWD/volumes/restic-repo:/data/restic-repo" -v ~/restore:/restore \
  mazzolino/restic:1.8.2 restore latest --target /restore
# -> ~/restore/data/backups/... and ~/restore/data/storage/...
```

To pull the repo from the remote first (host lost):

```bash
docker run --rm --entrypoint rclone \
  -v "$PWD/volumes/rclone:/root/.config/rclone" \
  -v "$PWD/volumes/restic-repo:/data/restic-repo" \
  mazzolino/restic:1.8.2 sync "$REMOTE" /data/restic-repo
```

### A. Restore a dump into a scratch database (safe - touches nothing live)

Use this to inspect a backup, verify it, or pull individual rows/tables out of
it. Use the same image as `db` in `docker-compose.yml` (its `psql` must be 17.x:
the dumps contain `\restrict` lines that older clients reject):

```bash
DUMP=backups/last/postgres-latest.sql.gz        # or any other dump
docker run -d --name pg-restore-test --network none -e POSTGRES_PASSWORD=scratch supabase/postgres:17.6.1.136
until docker exec pg-restore-test pg_isready -U supabase_admin -q; do sleep 2; done; sleep 10   # first-boot init
docker exec pg-restore-test psql -U supabase_admin -d postgres -q \
  -c 'create role supabase_realtime_admin nologin noinherit' \
  -c 'create role supabase_functions_admin nologin noinherit' \
  -c 'create database restore template template0'
zcat "$DUMP" | docker exec -i pg-restore-test psql -U supabase_admin -d restore -q 2>&1 | grep ERROR   # expect no output
docker exec pg-restore-test psql -U supabase_admin -d restore -c 'select (select count(*) from auth.users) users, (select count(*) from public.items) items'
```

- **Restore into the new, empty `restore` database, not `postgres`.** The image
  pre-creates an older `auth` schema in `postgres`, and the dump's `auth` tables
  collide with it: `auth.users` ends up with **0 rows** while `public` looks fine.
- The two roles are created by the running stack, not by the image. Without them
  the data still loads, but statements that mention them fail.
- `--network none` keeps the restored triggers (which call the Storage API when
  rows are deleted) from reaching anything live.

Compare counts with the live DB (small differences since the dump are normal):

```bash
docker exec supabase-db psql -U postgres -c 'select (select count(*) from auth.users) users, (select count(*) from public.items) items'
```

Remove the scratch container when done: `docker rm -f pg-restore-test`.

### B. Recover specific rows or tables into the live database

Extract only what you need from the scratch database (A), then load it live
without overwriting existing rows:

```bash
docker exec pg-restore-test pg_dump -U supabase_admin -d restore \
  --data-only --column-inserts --on-conflict-do-nothing -t public.items > items-recovered.sql
docker exec -i supabase-db psql -U postgres -d postgres < items-recovered.sql
```

Review the file first. `--on-conflict-do-nothing` keeps current rows; to
overwrite rows, delete them first or load into a staging table and merge.

### C. Restore uploaded files

Storage objects and the `storage.objects` rows must come from the same point in
time, so restore files from the same snapshot/archive as the dump.

```bash
docker compose stop storage imgproxy
rsync -a ~/restore/data/storage/ volumes/storage/        # from a restic restore
# or, from the pull script's archive:  tar -xzf giftamizer-backup-*.tar.gz -C /tmp/gb && rsync -a /tmp/gb/storage/ volumes/storage/
docker compose start storage imgproxy
```

### D. Full disaster recovery (new host)

1. Install Docker, clone this repo to `/giftamizer/backend`, restore `.env`
   (same `JWT_SECRET`, `ANON_KEY`, `SERVICE_ROLE_KEY`) and `volumes/rclone/rclone.conf`
   from your off-server copies. **Take `restic-backup` out of `COMPOSE_PROFILES`
   before starting anything**, so no new repository is created and no backup of
   the half-restored stack is taken.
2. Run `bash scripts/pull-offsite-backup.sh` and unpack the archive.
3. Restore the storage files (C) and the database dump into an empty database
   (the dump is a plain, non-`--clean` dump of the whole `postgres` database, so
   it needs an empty target rather than one already initialised by the stack's
   init scripts). Step A shows the dump loads cleanly into an empty `template0`
   database once the two roles exist; using that as the stack's `postgres`
   database is not scripted or rehearsed yet - test it on a scratch machine and
   add the exact steps here once it works.
4. Start the stack without `restic-backup` and check it.
5. Pull the offsite repository into the empty `volumes/restic-repo` (the `sync
   "$REMOTE" /data/restic-repo` command under "Get the backup files") so the
   snapshot history continues, then re-enable backups (`COMPOSE_PROFILES`, step
   "Offsite" above).

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| No new dump, `db-backup` logs `server version mismatch` | `db-backup` image major version differs from `db`. Bump the tag in `docker-compose.yml` to match, then `docker compose up -d db-backup`. |
| One failed connection in `db-backup` logs right after a host reboot | Harmless: Docker's restart policy doesn't honour `depends_on` health ordering. The next run succeeds. |
| `rclone config` prompts for a restic repository password | You forgot `--entrypoint rclone`. The image's own entrypoint tries to initialise a repo. Press Ctrl+C. |
| `unknown command "restic" for "restic"` | You passed `restic` after the image name. The image already runs restic - pass only its arguments (`snapshots`, `restore ...`). |
| `Fatal: repository does not exist ... /mnt/restic` | `RESTIC_REPOSITORY` wasn't set on that `docker run`, so the entrypoint looked at its default. Use the helper functions above. |
| `unable to create lock` / `repository is already locked` | A backup/prune is running, or one was killed. Wait, then `restic unlock` if the lock is stale. |
| `offsite-sync: FAILED after 3 attempts`, or `supabase-restic-backup` is `unhealthy` | The offsite sync failed (credentials, quota, network). Test: `rcl lsd "$REMOTE"`. The local snapshot was still taken, and the next run syncs it. Retry now with `docker compose restart restic-backup`. |
| `Backup already running, skipping backup` every night | A stale `/run/lock/backup.lock` left by a run that died. `POST_COMMANDS_EXIT` in `docker-compose.yml` removes it after a failed sync; if it still happens, `docker compose restart restic-backup` clears it. |
| `offsite-sync: REFUSED ... different restic repository` | The local repo was re-created (empty `volumes/restic-repo`) while the remote still has the old one. To keep the old snapshots, stop both restic containers, empty `volumes/restic-repo` and pull the remote into it. To start over, point `RCLONE_REMOTE` at a new path. |
| `RCLONE_REMOTE` empty / sync errors immediately | `RCLONE_REMOTE` is missing from `.env`. Add it and `docker compose up -d restic-backup restic-prune`. |
| Disk filling up | `du -sh backups volumes/restic-repo volumes/storage`; lower `*_KEEP_*` values or confirm `restic-prune` is running. |
| Restic times look off by hours | They use `TZ` from `.env`; the dump job always uses UTC. |
