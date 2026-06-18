#!/usr/bin/env bash
# Stop and remove GSAD GPU host agent systemd services.
set -euo pipefail

INSTALL_ROOT="/opt/gsad-agent"
CONFIG_DIR="/etc/gsad-agent"
PROVISIONER_SERVICE="gsad-account-provisioner.service"
REPORTER_SERVICE="gsad-gpu-server-report.service"

PURGE=0

log() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: uninstall.sh [--purge]

  --purge   Remove /opt/gsad-agent and /etc/gsad-agent
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
    log "Install tree kept at ${INSTALL_ROOT}"
    log "Config kept at ${CONFIG_DIR}/ (use --purge to remove)"
    return
  fi
  log "Purging ${INSTALL_ROOT} and ${CONFIG_DIR}"
  rm -rf "${INSTALL_ROOT}" "${CONFIG_DIR}"
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
