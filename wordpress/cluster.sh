#!/usr/bin/env bash
set -euo pipefail

# Start/kill helper for whatever config is currently in active/. Use
# apply-config.sh to pick/switch configs - this script just starts or
# kills the one already applied.

C='\033[0;36m'
Y='\033[1;33m'
G='\033[0;32m'
R='\033[0;31m'
N='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTIVE_DIR="${SCRIPT_DIR}/active"

compose() {
    if docker compose version &>/dev/null; then
        docker compose "$@"
    else
        docker-compose "$@"
    fi
}

usage() {
    printf "Usage: %s {start|kill|status}\n\n" "$0"
    printf "  start   docker compose up -d on the active config\n"
    printf "  kill    docker compose down -v on the active config (drops volumes too)\n"
    printf "  status  docker compose ps on the active config\n"
    exit 1
}

[[ $# -eq 1 ]] || usage

if [[ ! -f "${ACTIVE_DIR}/docker-compose.yml" ]]; then
    printf "${R}No active config in %s — run ./apply-config.sh first${N}\n" "$ACTIVE_DIR"
    exit 1
fi

case "$1" in
    start)
        printf "${G}==> starting $(cat "${ACTIVE_DIR}/.current-config" 2>/dev/null || echo active config)${N}\n"
        (cd "$ACTIVE_DIR" && compose up -d)
        (cd "$ACTIVE_DIR" && compose ps)
        ;;

    kill)
        printf "${R}This will stop containers and delete volumes (db/wp data) for the active config${N}\n"
        printf "${Y}Are you sure? (y/N): ${N}"
        read -r confirm
        if [[ "${confirm,,}" != "y" ]]; then
            printf "Aborted.\n"
            exit 0
        fi
        printf "${G}==> killing $(cat "${ACTIVE_DIR}/.current-config" 2>/dev/null || echo active config)${N}\n"
        (cd "$ACTIVE_DIR" && compose down -v)
        ;;

    status)
        (cd "$ACTIVE_DIR" && compose ps)
        ;;

    *)
        usage
        ;;
esac
