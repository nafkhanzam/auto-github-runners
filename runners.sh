#!/usr/bin/env bash
# Manage native GitHub Actions runners as systemd *user* units (no root/sudo needed).
# Each runner N lives in $RUNNER_BASE_DIR/runner-N and runs as github-runner@N.service.
#
#   ./runners.sh scale <N>     ensure exactly N runners (creates/removes as needed)
#   ./runners.sh status        show unit status
#   ./runners.sh logs [N]      follow logs (all runners, or runner N)
#   ./runners.sh restart       restart all runners
#   ./runners.sh down          remove all runners, deregister, delete unit
#
# Run as the user the runners should run as (jobs get this user's permissions).
# Requires lingering (loginctl enable-linger) so runners survive logout and start on boot.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-${ROOT}/.env}"
UNIT="github-runner"
UNIT_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/systemd/user"
UNIT_FILE="${UNIT_DIR}/${UNIT}@.service"

die() { echo "error: $*" >&2; exit 1; }

[[ -f "$ENV_FILE" ]] || die "missing ${ENV_FILE} (copy .env.example)"
[[ "$(id -u)" -ne 0 ]] || die "run as the runner user, not root"
for bin in curl jq tar flock sha256sum systemctl loginctl; do
  command -v "$bin" >/dev/null || die "missing dependency: ${bin}"
done

# systemctl --user needs this user's own session bus. `su`/`sudo -u` don't provide one.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
sctl() { systemctl --user "$@"; }
sctl show-environment >/dev/null 2>&1 ||
  die "cannot reach the systemd user manager; log in directly as $(id -un) (ssh or console), not via su"

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

BASE_DIR="${RUNNER_BASE_DIR:-${ROOT}/runners}"
[[ "$BASE_DIR" == /* ]] || BASE_DIR="${ROOT}/${BASE_DIR}"

existing_ids() {
  local d
  for d in "${BASE_DIR}"/runner-*; do
    [[ -d "$d" ]] && echo "${d##*/runner-}"
  done | sort -n
}

ensure_linger() {
  [[ "$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null)" == yes ]] && return
  if loginctl enable-linger "$(id -un)" 2>/dev/null; then
    echo "Enabled lingering for $(id -un)."
  else
    echo "warning: lingering is off and could not be enabled without an admin." >&2
    echo "         Runners will stop when you log out and won't start on boot." >&2
    echo "         Ask an admin to run: loginctl enable-linger $(id -un)" >&2
  fi
}

install_unit() {
  mkdir -p "$UNIT_DIR"
  cat >"$UNIT_FILE" <<EOF
[Unit]
Description=GitHub Actions runner %i
# User managers can't order on system network-online.target; start.sh retries via Restart=.

[Service]
Type=simple
EnvironmentFile=${ENV_FILE}
Environment=RUNNER_ID=%i
Environment=RUNNER_DIR=${BASE_DIR}/runner-%i
Environment=RUNNER_CACHE_DIR=${BASE_DIR}/.cache
ExecStart=${ROOT}/start.sh
Restart=always
RestartSec=5
# SIGTERM goes to start.sh only; it stops run.sh and deregisters if configured.
KillMode=mixed
TimeoutStopSec=10min

[Install]
WantedBy=default.target
EOF
  sctl daemon-reload
}

destroy_runner() {
  local id="$1"
  echo "Removing runner ${id}..."
  sctl disable --now "${UNIT}@${id}.service" 2>/dev/null || true
  RUNNER_ID="$id" RUNNER_DIR="${BASE_DIR}/runner-${id}" RUNNER_CACHE_DIR="${BASE_DIR}/.cache" \
    "${ROOT}/start.sh" remove || true
  rm -rf "${BASE_DIR:?}/runner-${id}"
}

cmd_scale() {
  local n="${1:-}"
  [[ "$n" =~ ^[0-9]+$ ]] || die "usage: $0 scale <N>"
  mkdir -p "$BASE_DIR"
  ensure_linger
  install_unit

  local id
  for ((id = 1; id <= n; id++)); do
    mkdir -p "${BASE_DIR}/runner-${id}"
    sctl enable --now "${UNIT}@${id}.service"
  done
  for id in $(existing_ids); do
    ((id > n)) && destroy_runner "$id"
  done
  cmd_status
}

cmd_status() {
  sctl list-units "${UNIT}@*.service" --all --no-pager
}

cmd_logs() {
  if [[ -n "${1:-}" ]]; then
    journalctl --user -u "${UNIT}@${1}.service" -f
  else
    journalctl --user -u "${UNIT}@*.service" -f
  fi
}

cmd_restart() {
  sctl restart "${UNIT}@*.service"
}

cmd_down() {
  local id
  for id in $(existing_ids); do destroy_runner "$id"; done
  rm -f "$UNIT_FILE"
  sctl daemon-reload
}

case "${1:-}" in
  scale) cmd_scale "${2:-}" ;;
  status) cmd_status ;;
  logs) cmd_logs "${2:-}" ;;
  restart) cmd_restart ;;
  down) cmd_down ;;
  *) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
