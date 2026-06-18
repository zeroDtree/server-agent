#!/usr/bin/env bash
# Install or upgrade GSAD GPU host agents (account-provisioner + gpu-server-report).
set -euo pipefail

INSTALL_ROOT="/opt/gsad-agent"
CONFIG_DIR="/etc/gsad-agent"
UV_BIN="${UV_BIN:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PROVISIONER_SERVICE="gsad-account-provisioner.service"
REPORTER_SERVICE="gsad-gpu-server-report.service"

log() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "Run as root: sudo $0"
  fi
}

require_linux() {
  uname -s | grep -qi linux || die "This installer supports Linux only"
}

_uv_candidate() {
  local candidate="$1"
  [[ -n "${candidate}" && -x "${candidate}" ]] || return 1
  UV_BIN="${candidate}"
  return 0
}

require_uv() {
  if [[ -n "${UV_BIN:-}" ]]; then
    _uv_candidate "${UV_BIN}" || die "UV_BIN is set but not executable: ${UV_BIN}"
    log "Using uv: ${UV_BIN}"
    return
  fi

  local path_uv
  path_uv="$(command -v uv 2>/dev/null || true)"
  if [[ -n "${path_uv}" ]] && _uv_candidate "${path_uv}"; then
    log "Using uv: ${UV_BIN}"
    return
  fi

  if [[ -n "${SUDO_USER:-}" ]]; then
    local sudo_home
    sudo_home="$(getent passwd "${SUDO_USER}" | cut -d: -f6)"
    if [[ -n "${sudo_home}" ]]; then
      _uv_candidate "${sudo_home}/.local/bin/uv" && { log "Using uv: ${UV_BIN}"; return; }
      _uv_candidate "${sudo_home}/.cargo/bin/uv" && { log "Using uv: ${UV_BIN}"; return; }
    fi
  fi

  _uv_candidate "/usr/local/bin/uv" && { log "Using uv: ${UV_BIN}"; return; }
  _uv_candidate "/usr/bin/uv" && { log "Using uv: ${UV_BIN}"; return; }

  die "uv not found. Install uv (https://docs.astral.sh/uv/) or run:
  sudo UV_BIN=/path/to/uv $0"
}

check_isolation() {
  local isolation="${SOURCE_ROOT}/account-provisioner/isolation/add-user.sh"
  [[ -f "${isolation}" ]] || die \
    "Missing isolation scripts. Run: git submodule update --init --recursive"
}

sync_agent_tree() {
  log "Syncing agents to ${INSTALL_ROOT}"
  mkdir -p "${INSTALL_ROOT}"

  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete \
      --exclude '.git' \
      --exclude '.venv' \
      --exclude '__pycache__' \
      --exclude '*.pyc' \
      "${SOURCE_ROOT}/account-provisioner/" "${INSTALL_ROOT}/account-provisioner/"
    rsync -a --delete \
      --exclude '.git' \
      --exclude '.venv' \
      --exclude '__pycache__' \
      --exclude '*.pyc' \
      "${SOURCE_ROOT}/gpu-server-report/" "${INSTALL_ROOT}/gpu-server-report/"
    rsync -a "${SOURCE_ROOT}/README.md" "${INSTALL_ROOT}/README.md" 2>/dev/null || true
  else
    rm -rf "${INSTALL_ROOT}/account-provisioner" "${INSTALL_ROOT}/gpu-server-report"
    cp -a "${SOURCE_ROOT}/account-provisioner" "${INSTALL_ROOT}/"
    cp -a "${SOURCE_ROOT}/gpu-server-report" "${INSTALL_ROOT}/"
    rm -rf \
      "${INSTALL_ROOT}/account-provisioner/.git" \
      "${INSTALL_ROOT}/account-provisioner/.venv" \
      "${INSTALL_ROOT}/gpu-server-report/.git" \
      "${INSTALL_ROOT}/gpu-server-report/.venv" 2>/dev/null || true
    [[ -f "${SOURCE_ROOT}/README.md" ]] && cp -a "${SOURCE_ROOT}/README.md" "${INSTALL_ROOT}/README.md"
  fi
}

install_env_file() {
  local name="$1"
  local example="$2"
  local dest="${CONFIG_DIR}/${name}"

  mkdir -p "${CONFIG_DIR}"
  if [[ ! -f "${dest}" ]]; then
    cp "${example}" "${dest}"
    chmod 600 "${dest}"
    log "Created ${dest} (edit before production use)"
  else
    log "Keeping existing ${dest}"
  fi
}

apply_env_overrides() {
  local common="${CONFIG_DIR}/common.env"
  touch "${common}"
  chmod 600 "${common}"

  if [[ -n "${GSAD_API_URL:-}" ]]; then
    if grep -q '^GSAD_API_URL=' "${common}" 2>/dev/null; then
      sed -i "s|^GSAD_API_URL=.*|GSAD_API_URL=${GSAD_API_URL}|" "${common}"
    else
      printf 'GSAD_API_URL=%s\n' "${GSAD_API_URL}" >> "${common}"
    fi
  fi
  if [[ -n "${AGENT_PSK:-}" ]]; then
    if grep -q '^AGENT_PSK=' "${common}" 2>/dev/null; then
      sed -i "s|^AGENT_PSK=.*|AGENT_PSK=${AGENT_PSK}|" "${common}"
    else
      printf 'AGENT_PSK=%s\n' "${AGENT_PSK}" >> "${common}"
    fi
  fi
  if [[ -n "${AGENT_HOSTNAME:-}" ]]; then
    if grep -q '^AGENT_HOSTNAME=' "${common}" 2>/dev/null; then
      sed -i "s|^AGENT_HOSTNAME=.*|AGENT_HOSTNAME=${AGENT_HOSTNAME}|" "${common}"
    else
      printf 'AGENT_HOSTNAME=%s\n' "${AGENT_HOSTNAME}" >> "${common}"
    fi
  fi
}

uv_sync_agent() {
  local dir="$1"
  log "uv sync in ${dir}"
  (cd "${dir}" && "${UV_BIN}" sync --frozen)
}

install_systemd_unit() {
  local unit="$1"
  local src="${SCRIPT_DIR}/systemd/${unit}"
  local dest="/etc/systemd/system/${unit}"

  sed "s|@UV_BIN@|${UV_BIN}|g" "${src}" > "${dest}"
  chmod 644 "${dest}"
}

install_systemd_units() {
  log "Installing systemd units (uv: ${UV_BIN})"
  install_systemd_unit "${PROVISIONER_SERVICE}"
  install_systemd_unit "${REPORTER_SERVICE}"
  systemctl daemon-reload
  systemctl enable "${PROVISIONER_SERVICE}" "${REPORTER_SERVICE}"
  systemctl restart "${PROVISIONER_SERVICE}" "${REPORTER_SERVICE}"
}

wait_for_health() {
  local url="$1"
  local label="$2"
  local i

  for i in $(seq 1 30); do
    if curl -sf "${url}" >/dev/null 2>&1; then
      log "${label} health OK (${url})"
      return 0
    fi
    sleep 1
  done
  log "WARN: ${label} health check timed out (${url}) — check journalctl"
  return 1
}

verify_services() {
  systemctl is-active --quiet "${PROVISIONER_SERVICE}" || die "${PROVISIONER_SERVICE} is not active"
  systemctl is-active --quiet "${REPORTER_SERVICE}" || die "${REPORTER_SERVICE} is not active"

  wait_for_health "http://127.0.0.1:9091/health" "account-provisioner" || true
  wait_for_health "http://127.0.0.1:9092/health" "gpu-server-report" || true
}

main() {
  require_root
  require_linux
  require_uv
  check_isolation

  install_env_file "common.env" "${SCRIPT_DIR}/env/common.env.example"
  install_env_file "provisioner.env" "${SCRIPT_DIR}/env/provisioner.env.example"
  install_env_file "reporter.env" "${SCRIPT_DIR}/env/reporter.env.example"
  apply_env_overrides

  sync_agent_tree
  uv_sync_agent "${INSTALL_ROOT}/account-provisioner"
  uv_sync_agent "${INSTALL_ROOT}/gpu-server-report"

  install_systemd_units
  verify_services

  log "Installation complete"
  log "Config: ${CONFIG_DIR}/"
  log "Logs: journalctl -u ${PROVISIONER_SERVICE} -u ${REPORTER_SERVICE} -f"
}

main "$@"
