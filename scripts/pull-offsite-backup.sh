#!/usr/bin/env bash
# Pull the offsite (rclone) restic backup down and package the database dump
# and the uploaded storage files into ONE compressed archive.
#
# Usage:
#   ./pull-offsite-backup.sh [snapshot-id|latest] [destination-dir]
#
# Defaults: snapshot "latest", destination ~ (the running user's home dir).
#
# Produces a single file, <destination>/giftamizer-backup-<dump-timestamp>.tar.gz:
#   database/postgres-<timestamp>.sql.gz   the database dump from that snapshot
#   storage/...                            the uploaded files (items, avatars, ...)
# The timestamp in the name is when the dump was taken, so it tells you how old
# the data is. Everything else (the pulled restic repo, the extracted snapshot)
# is built in a temporary work directory and deleted when the script finishes;
# set KEEP_WORK=1 to keep it for debugging.
#
# It only READS from the remote and never touches the live ./volumes/restic-repo,
# ./backups or ./volumes/storage, so it's safe to run on the production host.
# Needs Docker, and the backend's .env (RCLONE_REMOTE, RESTIC_PASSWORD) plus
# volumes/rclone/rclone.conf. Run it on the server, or set BACKEND_DIR to the
# backend install directory (defaults to this repo, else /giftamizer/backend).
# Free space needed: roughly 2-3x the size of the storage files (the pulled
# repo + the extracted files + the archive) in the destination filesystem.
#
# Restoring from the archive (stop storage/imgproxy first when copying files
# back) is described in README.md under "Offsite backup" / "Restoring".

set -euo pipefail

IMAGE="mazzolino/restic:1.8.2"
SNAPSHOT="${1:-latest}"
DEST="${2:-$HOME}"
DEST="${DEST/#\~/$HOME}" # expand a literal leading ~ (e.g. when passed quoted)

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -n "${BACKEND_DIR:-}" ]]; then
	backend_dir="$BACKEND_DIR"
elif [[ -f "$script_dir/../docker-compose.yml" ]]; then
	backend_dir="$(cd "$script_dir/.." && pwd)"
else
	backend_dir="/giftamizer/backend"
fi

env_file="$backend_dir/.env"
rclone_conf_dir="$backend_dir/volumes/rclone"

[[ -f "$env_file" ]] || { echo "Missing $env_file (set BACKEND_DIR to the backend install dir)." >&2; exit 1; }
[[ -f "$rclone_conf_dir/rclone.conf" ]] || { echo "Missing $rclone_conf_dir/rclone.conf - configure the rclone remote first." >&2; exit 1; }

# Read single values from .env without sourcing it (it holds many unrelated secrets).
get_env() { grep -E "^$1=" "$env_file" | head -n1 | cut -d= -f2-; }

RCLONE_REMOTE="$(get_env RCLONE_REMOTE)"
RESTIC_PASSWORD="$(get_env RESTIC_PASSWORD)"
[[ -n "$RCLONE_REMOTE" ]] || { echo "RCLONE_REMOTE is not set in $env_file." >&2; exit 1; }
[[ -n "$RESTIC_PASSWORD" ]] || { echo "RESTIC_PASSWORD is not set in $env_file." >&2; exit 1; }
export RESTIC_PASSWORD # passed to docker by name so it never shows up in `ps`

mkdir -p "$DEST"
work="$(mktemp -d "$DEST/.giftamizer-restore-work.XXXXXX")"
repo="$work/repo"
restore="$work/restore"
mkdir -p "$repo" "$restore"

# Docker runs as root, so files it creates in $work are root-owned. Hand them
# back to this user (needed to delete them) and then remove the work dir.
cleanup() {
	docker run --rm --entrypoint chown -v "$work:/work" "$IMAGE" -R "$(id -u):$(id -g)" /work >/dev/null 2>&1 || true
	if [[ "${KEEP_WORK:-0}" == "1" ]]; then
		echo "Work directory kept: $work"
	else
		rm -rf "$work"
	fi
}
trap cleanup EXIT

echo "==> Pulling restic repository from $RCLONE_REMOTE"
docker run --rm --entrypoint rclone \
	-v "$rclone_conf_dir:/root/.config/rclone" \
	-v "$repo:/data/restic-repo" \
	"$IMAGE" sync "$RCLONE_REMOTE" /data/restic-repo --stats-one-line -v

echo "==> Restoring snapshot '$SNAPSHOT'"
docker run --rm -e RESTIC_PASSWORD \
	-e RESTIC_REPOSITORY=/data/restic-repo \
	-v "$repo:/data/restic-repo" \
	-v "$restore:/restore" \
	"$IMAGE" restore "$SNAPSHOT" --target /restore

# Hand ownership of the restored files to this user before touching them.
docker run --rm --entrypoint chown -v "$work:/work" "$IMAGE" -R "$(id -u):$(id -g)" /work

backups="$restore/data/backups"
storage="$restore/data/storage"
[[ -d "$storage" ]] || { echo "Snapshot has no storage files at $storage." >&2; exit 1; }

# The dump: backups/last/ holds the newest timestamped dump (plus a
# postgres-latest.sql.gz symlink to it, which the [0-9]* glob skips so we get
# the real file and its timestamp). Fall back to the newest daily dump.
dump="$(ls -1t "$backups"/last/postgres-[0-9]*.sql.gz 2>/dev/null | head -n1 || true)"
[[ -n "$dump" ]] || dump="$(ls -1t "$backups"/daily/postgres-[0-9]*.sql.gz 2>/dev/null | head -n1 || true)"
[[ -n "$dump" && -f "$dump" ]] || { echo "No database dump found in the snapshot ($backups)." >&2; exit 1; }

stamp="$(basename "$dump" .sql.gz)" # postgres-20261121-000000
stamp="${stamp#postgres-}"          # 20261121-000000
archive="$DEST/giftamizer-backup-$stamp.tar.gz"

echo "==> Packaging $(basename "$dump") + storage files"
pkg="$work/package"
mkdir -p "$pkg/database"
cp "$dump" "$pkg/database/postgres-$stamp.sql.gz"
mv "$storage" "$pkg/storage" # same filesystem, so this is instant

tar -czf "$archive.partial" -C "$pkg" database storage
mv "$archive.partial" "$archive"

echo
echo "Done: $archive ($(du -h "$archive" | cut -f1))"
echo "  database/postgres-$stamp.sql.gz"
echo "  storage/  ($(find "$pkg/storage" -type f | wc -l) files)"
