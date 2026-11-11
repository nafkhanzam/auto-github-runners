#!/usr/bin/env bash
# Runs one GitHub Actions runner in $RUNNER_DIR (registers fresh, runs, cleans up).
#   start.sh          register + run (foreground; SIGTERM stops gracefully)
#   start.sh remove   deregister the runner in $RUNNER_DIR
# Invoked by the github-runner@.service systemd units (see runners.sh).
set -Eeuo pipefail

: "${REPO:?REPO env var required (<owner>/<repo> or <org>)}"
: "${NAME:?NAME env var required}"
: "${ACCESS_TOKEN:?ACCESS_TOKEN env var required (GitHub PAT)}"

RUNNER_DIR="${RUNNER_DIR:?RUNNER_DIR env var required}"
API_URL="${GITHUB_API_URL:-https://api.github.com}"
RUNNER_NAME="${NAME}-$(hostname)${RUNNER_ID:+-${RUNNER_ID}}"

if [[ "$REPO" == */* ]]; then
  API_SCOPE="repos/${REPO}"
else
  API_SCOPE="orgs/${REPO}"
fi

gh_api() {
  curl -fsSL \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$@"
}

# $1 = registration-token | remove-token
# Mints a fresh short-lived token from ACCESS_TOKEN on every call.
fetch_token() {
  gh_api -X POST "${API_URL}/${API_SCOPE}/actions/runners/$1" | jq -r '.token'
}

installed_version() {
  [[ -x "${RUNNER_DIR}/bin/Runner.Listener" ]] || return 0
  "${RUNNER_DIR}/bin/Runner.Listener" --version 2>/dev/null || true
}

# Ensure $RUNNER_DIR holds the latest runner release; runs on every start.
# - Tarball is cached in $RUNNER_CACHE_DIR, downloaded once and shared by all
#   runners; the whole step is serialized with flock.
# - Older cached tarballs are pruned.
# - If GitHub is unreachable but a runner is already installed, keep using it.
# Running runners also self-update in place when GitHub announces a new release.
ensure_runner_latest() {
  local arch
  case "$(uname -m)" in
    x86_64) arch=x64 ;;
    aarch64 | arm64) arch=arm64 ;;
    armv7l) arch=arm ;;
    *) echo "Unsupported architecture: $(uname -m)" >&2; return 1 ;;
  esac

  local current release
  current=$(installed_version)
  if ! release=$(gh_api "${API_URL}/repos/actions/runner/releases/latest"); then
    [[ -n "$current" ]] || { echo "Cannot fetch latest runner release" >&2; return 1; }
    echo "WARNING: cannot check latest release, keeping installed ${current}" >&2
    return 0
  fi

  local version
  version=$(jq -r '.tag_name | ltrimstr("v")' <<<"$release")
  if [[ "$current" == "$version" ]]; then
    echo "Runner ${version} is up to date."
    return 0
  fi

  local file sha cache
  file="actions-runner-linux-${arch}-${version}.tar.gz"
  # Release notes embed checksums as <!-- BEGIN SHA linux-x64 -->...<!-- END SHA linux-x64 -->
  sha=$(jq -r '.body' <<<"$release" |
    sed -n "s/.*<!-- BEGIN SHA linux-${arch} -->\([0-9a-f]\{64\}\)<!-- END SHA linux-${arch} -->.*/\1/p" | head -n1)
  cache="${RUNNER_CACHE_DIR:-$(dirname "$RUNNER_DIR")/.cache}"
  mkdir -p "$cache" "$RUNNER_DIR"

  (
    flock 9
    if [[ ! -f "${cache}/${file}" ]]; then
      echo "Downloading ${file}..."
      curl -fsSL -o "${cache}/${file}.part" \
        "https://github.com/actions/runner/releases/download/v${version}/${file}"
      if [[ -n "$sha" ]]; then
        echo "${sha}  ${cache}/${file}.part" | sha256sum -c --quiet -
      else
        echo "WARNING: no checksum found in release notes, skipping verification" >&2
      fi
      mv "${cache}/${file}.part" "${cache}/${file}"
    fi
    find "$cache" -maxdepth 1 -name 'actions-runner-linux-*.tar.gz*' ! -name "$file" -delete

    echo "Installing runner ${version} (was: ${current:-none})..."
    # Wipe the old install but keep the job workspace.
    find "$RUNNER_DIR" -mindepth 1 -maxdepth 1 ! -name "${WORK_DIR:-_work}" -exec rm -rf {} +
    tar xzf "${cache}/${file}" -C "$RUNNER_DIR"
  ) 9>"${cache}/.lock"
}

remove_runner() {
  [[ -f .runner ]] || { echo "No runner configured in ${RUNNER_DIR}"; return 0; }
  echo "Removing runner ${RUNNER_NAME}..."
  ./config.sh remove --token "$(fetch_token remove-token)" || echo "Runner removal failed" >&2
}

if [[ "${1:-}" == "remove" ]]; then
  cd "$RUNNER_DIR" 2>/dev/null || { echo "No runner in ${RUNNER_DIR}"; exit 0; }
  remove_runner
  exit 0
fi

ensure_runner_latest
cd "$RUNNER_DIR"

# Always register fresh: a leftover .runner from a previous run may be stale
# (ephemeral runner already deregistered, or removed server-side). --replace
# reclaims the same name, which is stable across restarts.
rm -f .runner .credentials .credentials_rsaparams

config_args=(
  --unattended
  --replace
  --url "https://github.com/${REPO}"
  --token "$(fetch_token registration-token)"
  --name "$RUNNER_NAME"
)
[[ -n "${LABELS:-}" ]] && config_args+=(--labels "$LABELS")
[[ -n "${RUNNER_GROUP:-}" ]] && config_args+=(--runnergroup "$RUNNER_GROUP")
[[ -n "${WORK_DIR:-}" ]] && config_args+=(--work "$WORK_DIR")
[[ "${EPHEMERAL:-false}" == "true" ]] && config_args+=(--ephemeral)

./config.sh "${config_args[@]}"

RUNNER_PID=""

cleanup() {
  trap - INT TERM
  # Stop the runner first; removal fails while it is still connected.
  if [[ -n "$RUNNER_PID" ]] && kill -0 "$RUNNER_PID" 2>/dev/null; then
    kill -TERM "$RUNNER_PID" 2>/dev/null || true
    wait "$RUNNER_PID" 2>/dev/null || true
  fi
  [[ "${REMOVE_RUNNER_ON_EXIT:-false}" == "true" ]] && remove_runner
  return 0
}

trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

./run.sh &
RUNNER_PID=$!

set +e
wait "$RUNNER_PID"
rc=$?
set -e

cleanup
exit "$rc"
