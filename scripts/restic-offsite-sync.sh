#!/usr/bin/env bash
# Mirror the local restic repository to RCLONE_REMOTE.
#
# Runs INSIDE the restic-backup / restic-prune containers as their
# POST_COMMANDS_SUCCESS (see docker-compose.yml) - not meant to be run on the host.
#
# On top of a plain `rclone sync` it:
#   - retries, each time with a fresh rclone process. rclone's own retries reuse
#     the failed session and gave up within the same millisecond on a transient
#     remote error.
#   - refuses to sync when the remote holds a DIFFERENT restic repository.
#     `restic init` runs automatically when ./volumes/restic-repo is empty (new
#     host, lost disk), and mirroring that new repo would delete every offsite
#     snapshot right when they are needed.
#   - skips locks/, so a lock held during the sync never ends up stale offsite.
#   - touches $MARKER on success, which the restic-backup healthcheck looks at.
#
# Exits non-zero when nothing was synced.

set -uo pipefail
exec </dev/null # the image feeds post-commands through stdin; don't eat them

REPO="${RESTIC_REPOSITORY:-/data/restic-repo}"
ATTEMPTS="${OFFSITE_SYNC_ATTEMPTS:-3}"
RETRY_SECONDS="${OFFSITE_SYNC_RETRY_SECONDS:-60}"
MARKER=/run/offsite-sync.ok

log() { echo "offsite-sync: $*"; }

[[ -n "${RCLONE_REMOTE:-}" ]] || { log "FAILED - RCLONE_REMOTE is not set"; exit 1; }
[[ -s "$REPO/config" ]] || { log "FAILED - no restic repository at $REPO"; exit 1; }

# restic's config file is written once by `restic init` and is unique to that
# repository, so comparing it tells whether both sides are the same repository.
# Returns 0 = safe to sync, 1 = couldn't tell (retry), 2 = different repository.
check_same_repo() {
	local listing rc
	listing="$(rclone lsf --files-only "$RCLONE_REMOTE")"
	rc=$?
	[[ $rc -eq 3 ]] && return 0 # directory doesn't exist yet: first sync
	[[ $rc -eq 0 ]] || return 1
	grep -qx config <<<"$listing" || return 0

	local remote_config
	remote_config="$(mktemp)"
	if ! rclone cat "$RCLONE_REMOTE/config" >"$remote_config"; then
		rm -f "$remote_config"
		return 1
	fi
	cmp -s "$remote_config" "$REPO/config"
	rc=$?
	rm -f "$remote_config"
	[[ $rc -eq 0 ]] || return 2
}

for ((attempt = 1; attempt <= ATTEMPTS; attempt++)); do
	check_same_repo
	case $? in
	0)
		if rclone sync "$REPO" "$RCLONE_REMOTE" --exclude '/locks/**'; then
			touch "$MARKER"
			log "synced to $RCLONE_REMOTE"
			exit 0
		fi
		;;
	2)
		log "REFUSED - $RCLONE_REMOTE holds a different restic repository than $REPO."
		log "Syncing would delete its snapshots. Pull it back first (backup.md, 'Full"
		log "disaster recovery'), or point RCLONE_REMOTE at a new path to start over."
		exit 1
		;;
	esac
	log "attempt $attempt/$ATTEMPTS failed"
	((attempt < ATTEMPTS)) && sleep "$RETRY_SECONDS"
done

log "FAILED after $ATTEMPTS attempts - the offsite copy is out of date"
exit 1
