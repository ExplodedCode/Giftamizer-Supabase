#!/bin/bash
#
# Thin convenience wrapper around the docker compose invocations used in this
# repo, so you don't need to remember the multi-file flags. Everything here
# is optional - a plain `docker compose -f ... up -d` works exactly the same.
#
# Usage:
#   ./run.sh dev  {up|down|restart|logs [service]|ps}   local dev stack (inbucket mail, fresh db)
#   ./run.sh prod {up|down|restart|logs [service]|ps}   production stack (no dev overrides)
#   ./run.sh reset                                       wipe everything and start over (see reset.sh)

set -euo pipefail
cd "$(dirname "$0")"

usage() {
  echo "Usage: $0 {dev|prod} {up|down|restart|logs [service]|ps}" >&2
  echo "   or: $0 reset" >&2
  exit 1
}

[ $# -ge 1 ] || usage

if [ "$1" = "reset" ]; then
  exec ./reset.sh
fi

env_name="$1"; shift
case "$env_name" in
  dev) FILES=(-f docker-compose.yml -f ./dev/docker-compose.dev.yml) ;;
  prod) FILES=(-f docker-compose.yml) ;;
  *) usage ;;
esac

[ $# -ge 1 ] || usage
action="$1"; shift

case "$action" in
  up)      docker compose "${FILES[@]}" up -d "$@" ;;
  down)    docker compose "${FILES[@]}" down "$@" ;;
  restart) docker compose "${FILES[@]}" restart "$@" ;;
  logs)    docker compose "${FILES[@]}" logs -f "$@" ;;
  ps)      docker compose "${FILES[@]}" ps "$@" ;;
  *)       usage ;;
esac
