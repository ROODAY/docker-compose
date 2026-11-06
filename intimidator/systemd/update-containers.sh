#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-$PWD}"
REPO_OWNER="${REPO_OWNER:-$(stat -c %U "$PROJECT_DIR")}"
GIT_URL="${GIT_URL:-https://github.com/ROODAY/docker-compose.git}"
BRANCH="${BRANCH:-main}"
LOCK_FILE="${LOCK_FILE:-${RUNTIME_DIRECTORY:-/tmp}/intimidator-update.lock}"

log() { printf '%s %s\n' "$(date -Is)" "$*"; }
die() { log "ERROR: $*"; exit 1; }

command -v flock >/dev/null || die "flock not found (install util-linux)"

if [[ "$(id -u)" -eq 0 ]]; then
  command -v runuser >/dev/null || die "runuser not found (install util-linux)"
  as_owner() { runuser -u "$REPO_OWNER" -- "$@"; }
else
  as_owner() { "$@"; }
fi

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  log "another update is already running; exiting"
  exit 0
fi

REPO_DIR="$(as_owner git -C "$PROJECT_DIR" rev-parse --show-toplevel)" \
  || die "cannot resolve repo root from $PROJECT_DIR"

# Keep the checkout on origin/main. Refuse to ship uncommitted intimidator state
# (tracked edits, staged edits, or untracked files under intimidator/).
status_out="$(as_owner git -C "$REPO_DIR" status --porcelain --untracked-files=all -- intimidator)" \
  || die "cannot read git status for $REPO_DIR"
if [[ -z "$status_out" ]]; then
  PREV="$(as_owner git -C "$REPO_DIR" rev-parse --short HEAD)"
  if as_owner git -C "$REPO_DIR" fetch --quiet "$GIT_URL" "$BRANCH"; then
    if as_owner git -C "$REPO_DIR" merge --ff-only --quiet FETCH_HEAD; then
      log "git: $PREV -> $(as_owner git -C "$REPO_DIR" rev-parse --short HEAD)"
    else
      die "checkout has diverged from $BRANCH; refusing to deploy non-main state"
    fi
  else
    log "WARNING: git fetch failed; deploying current checkout"
  fi
else
  if [[ "${ALLOW_DIRTY:-0}" == "1" ]]; then
    log "WARNING: dirty intimidator worktree; ALLOW_DIRTY=1 so deploying anyway"
  else
    die "dirty intimidator worktree; commit, discard, or rerun with ALLOW_DIRTY=1"
  fi
fi

# Sync the installed units from the repo copy. New unit versions apply next run.
if [[ -f "$REPO_DIR/intimidator/systemd/install.sh" ]]; then
  bash "$REPO_DIR/intimidator/systemd/install.sh" --if-changed \
    || log "WARNING: unit sync failed"
else
  log "WARNING: installer not found at $REPO_DIR/intimidator/systemd/install.sh"
fi

cd "$PROJECT_DIR"

command -v docker >/dev/null || die "docker CLI not found"

# Fail before touching containers if interpolation is invalid or any ${VAR} is
# unset. `config` exits 0 on an unset var and only prints a warning, so the
# warning text is checked as well.
config_out="$(docker compose config 2>&1)" || {
  printf '%s\n' "$config_out" >&2
  die "docker compose config failed; not deploying"
}
if grep -qi 'variable is not set' <<<"$config_out"; then
  grep -i 'variable is not set' <<<"$config_out" >&2
  die "compose variables are unset; check $PROJECT_DIR/.env"
fi

docker compose pull --ignore-pull-failures --quiet \
  || log "WARNING: one or more image pulls failed; continuing"

# One up for the whole project so Compose honours depends_on/restart ordering.
# No --wait: kometa and recyclarr exit by design, so --wait would fail every run.
docker compose up -d --remove-orphans \
  || die "docker compose up failed"

# Keep two weeks of previous images for rollback; never -a.
docker image prune -f --filter "until=336h" >/dev/null

log "deploy complete"
