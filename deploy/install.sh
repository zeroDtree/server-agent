#!/usr/bin/env bash
#
# -----------------------------------------------------------------------------
# install.sh — install systemd units for GSAD GPU host agents.
#
# Services run from THIS repository checkout (no copy to /opt or /etc).
# Config lives under deploy/env/*.env; units reference @REPO_ROOT@ paths.
# Re-run after moving the clone so systemd paths stay correct.
#
# Examples
#   sudo REPORT_API_URL=https://api.example AGENT_PSK=... AGENT_SERVER_ID=gpu-01 ./install.sh
# -----------------------------------------------------------------------------
set -euo pipefail

UV_BIN="${UV_BIN:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_DIR="${SOURCE_ROOT}/deploy/env"

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

install_env_file() {
  local name="$1"
  local example="${ENV_DIR}/${name}.example"
  local dest="${ENV_DIR}/${name}"

  mkdir -p "${ENV_DIR}"
  if [[ ! -f "${dest}" ]]; then
    cp "${example}" "${dest}"
    chmod 600 "${dest}"
    log "Created ${dest} (edit before production use)"
  else
    log "Keeping existing ${dest}"
  fi
}

set_common_env_var() {
  local file="$1"
  local key="$2"
  local value="$3"

  if grep -q "^${key}=" "${file}" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${value}|" "${file}"
  else
    printf '%s=%s\n' "${key}" "${value}" >> "${file}"
  fi
}

sync_upstream_api_url() {
  local common="$1"
  local report_url

  report_url="$(grep '^REPORT_API_URL=' "${common}" 2>/dev/null | cut -d= -f2- || true)"
  if [[ -z "${report_url}" ]]; then
    return 0
  fi

  set_common_env_var "${common}" UPSTREAM_API_URL "${report_url}"
}

apply_env_overrides() {
  local common="${ENV_DIR}/common.env"
  touch "${common}"
  chmod 600 "${common}"

  if [[ -n "${REPORT_API_URL:-}" ]]; then
    set_common_env_var "${common}" REPORT_API_URL "${REPORT_API_URL}"
    set_common_env_var "${common}" UPSTREAM_API_URL "${REPORT_API_URL}"
  fi
  if [[ -n "${AGENT_PSK:-}" ]]; then
    set_common_env_var "${common}" AGENT_PSK "${AGENT_PSK}"
  fi
  if [[ -n "${AGENT_SERVER_ID:-}" ]]; then
    set_common_env_var "${common}" AGENT_SERVER_ID "${AGENT_SERVER_ID}"
  fi

  sync_upstream_api_url "${common}"
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

  sed -e "s|@REPO_ROOT@|${SOURCE_ROOT}|g" \
      -e "s|@UV_BIN@|${UV_BIN}|g" \
      "${src}" > "${dest}"
  chmod 644 "${dest}"
}

install_systemd_units() {
  log "Installing systemd units (repo: ${SOURCE_ROOT}, uv: ${UV_BIN})"
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

  install_env_file "common.env"
  install_env_file "provisioner.env"
  install_env_file "reporter.env"
  apply_env_overrides

  uv_sync_agent "${SOURCE_ROOT}/account-provisioner"
  uv_sync_agent "${SOURCE_ROOT}/gpu-server-report"

  install_systemd_units
  verify_services

  log "Installation complete"
  log "Repo path: ${SOURCE_ROOT} (keep stable; re-run install after moving)"
  log "Config: ${ENV_DIR}/"
  log "Logs: journalctl -u ${PROVISIONER_SERVICE} -u ${REPORTER_SERVICE} -f"
}

main "$@"
