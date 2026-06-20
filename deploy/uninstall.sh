#!/usr/bin/env bash
# Stop and remove GSAD GPU host agent systemd services.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_DIR="${SOURCE_ROOT}/deploy/env"

PROVISIONER_SERVICE="gsad-account-provisioner.service"
REPORTER_SERVICE="gsad-gpu-server-report.service"

PURGE=0

log() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: uninstall.sh [--purge]

  --purge   Remove deploy/env/common.env, provisioner.env, reporter.env
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --purge) PURGE=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown option: $1 (try --help)" ;;
    esac
  done
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "Run as root: sudo $0"
  fi
}

stop_services() {
  log "Stopping systemd services"
  systemctl disable --now "${PROVISIONER_SERVICE}" 2>/dev/null || true
  systemctl disable --now "${REPORTER_SERVICE}" 2>/dev/null || true
}

remove_units() {
  log "Removing systemd unit files"
  rm -f \
    "/etc/systemd/system/${PROVISIONER_SERVICE}" \
    "/etc/systemd/system/${REPORTER_SERVICE}"
  systemctl daemon-reload
}

purge_files() {
  if [[ "${PURGE}" -ne 1 ]]; then
    log "Config kept at ${ENV_DIR}/ (use --purge to remove generated .env files)"
    return
  fi
  log "Removing generated env files in ${ENV_DIR}"
  rm -f \
    "${ENV_DIR}/common.env" \
    "${ENV_DIR}/provisioner.env" \
    "${ENV_DIR}/reporter.env"
}

main() {
  parse_args "$@"
  require_root
  stop_services
  remove_units
  purge_files
  log "Uninstall complete"
}

main "$@"
