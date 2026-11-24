#!/usr/bin/env bash
set -euo pipefail

# Lets you pick one of the WordPress configurations in this folder (each
# config is a subfolder containing its own docker-compose.yml, nginx.conf,
# etc.) and copies it into ./active/, bringing down whatever configuration
# is currently running there first, then brings the new one up.
#
# Add configurations as subfolders here, e.g.:
#   wordpress/single/docker-compose.yml
#   wordpress/scaled-lb/docker-compose.yml + nginx.conf
#   wordpress/galera/docker-compose.yml
#
# "active" and "apply-config.sh" itself are never listed as configs.

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

# ── discover available configurations ────────────────────────────────────────
configs=()
for dir in "$SCRIPT_DIR"/*/; do
    name="$(basename "$dir")"
    [[ "$name" == "active" ]] && continue
    if [[ -f "${dir}docker-compose.yml" || -f "${dir}docker-compose.yaml" ]]; then
        configs+=("$name")
    fi
done

if [[ ${#configs[@]} -eq 0 ]]; then
    printf "${R}No configurations found under %s${N}\n" "$SCRIPT_DIR"
    printf "Add a subfolder with its own docker-compose.yml (and nginx.conf etc.) first.\n"
    exit 1
fi

# ── show current state ────────────────────────────────────────────────────────
if [[ -f "${ACTIVE_DIR}/.current-config" ]]; then
    current="$(cat "${ACTIVE_DIR}/.current-config")"
    printf "${Y}Currently active: %s${N}\n\n" "$current"
fi

# ── pick a configuration ──────────────────────────────────────────────────────
printf "${G}Available WordPress configurations:${N}\n"
for i in "${!configs[@]}"; do
    printf "  %d) %s\n" "$((i + 1))" "${configs[$i]}"
done
printf "\n${Y}Select a configuration [1-%d]: ${N}" "${#configs[@]}"
read -r choice

if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#configs[@]} )); then
    printf "${R}Invalid selection.${N}\n"
    exit 1
fi

selected="${configs[$((choice - 1))]}"
printf "\n${G}==> applying configuration: %s${N}\n" "$selected"

# ── tear down whatever is currently running ──────────────────────────────────
if [[ -f "${ACTIVE_DIR}/docker-compose.yml" || -f "${ACTIVE_DIR}/docker-compose.yaml" ]]; then
    printf "${G}==> stopping currently active configuration${N}\n"
    (cd "$ACTIVE_DIR" && compose down)
fi

# ── copy the selected configuration into place ───────────────────────────────
printf "${G}==> copying %s into %s${N}\n" "$selected" "$ACTIVE_DIR"
rm -rf "$ACTIVE_DIR"
mkdir -p "$ACTIVE_DIR"
cp -r "${SCRIPT_DIR}/${selected}/." "$ACTIVE_DIR/"
echo "$selected" > "${ACTIVE_DIR}/.current-config"

# ── bring it up ───────────────────────────────────────────────────────────────
printf "${G}==> starting %s${N}\n" "$selected"
(cd "$ACTIVE_DIR" && compose up -d)

printf "\n${G}Done.${N} %s is now running from %s\n" "$selected" "$ACTIVE_DIR"
(cd "$ACTIVE_DIR" && compose ps)
