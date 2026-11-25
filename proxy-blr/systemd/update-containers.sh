#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-$PWD}"
REPO_OWNER="${REPO_OWNER:-$(stat -c %U "$PROJECT_DIR")}"
GIT_URL="${GIT_URL:-https://github.com/ROODAY/docker-compose.git}"
BRANCH="${BRANCH:-main}"
LOCK_FILE="${LOCK_FILE:-${RUNTIME_DIRECTORY:-/tmp}/proxy-blr-update.lock}"

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

# Keep the checkout on origin/main. Refuse to ship uncommitted state: tracked
# edits, staged edits, or untracked files under proxy-blr/ or under the shared
# plex-edge/ that this proxy's Traefik loads.
status_out="$(as_owner git -C "$REPO_DIR" status --porcelain --untracked-files=all -- proxy-blr plex-edge)" \
  || die "cannot read git status for $REPO_DIR"
if [[ -z "$status_out" ]]; then
  PREV="$(as_owner git -C "$REPO_DIR" rev-parse --short HEAD)"
  if as_owner git -C "$REPO_DIR" fetch --quiet "$GIT_URL" "$BRANCH"; then
    if as_owner git -C "$REPO_DIR" merge --ff-only --quiet FETCH_HEAD; then
      # The fetch above only writes FETCH_HEAD, so advance the remote-tracking
      # ref too; otherwise the checkout looks ahead of origin after a deploy.
      if as_owner git -C "$REPO_DIR" remote get-url origin >/dev/null 2>&1; then
        as_owner git -C "$REPO_DIR" update-ref "refs/remotes/origin/$BRANCH" FETCH_HEAD
      fi
      log "git: $PREV -> $(as_owner git -C "$REPO_DIR" rev-parse --short HEAD)"
    else
      die "checkout has diverged from $BRANCH; refusing to deploy non-main state"
    fi
  else
    log "WARNING: git fetch failed; deploying current checkout"
  fi
else
  if [[ "${ALLOW_DIRTY:-0}" == "1" ]]; then
    log "WARNING: dirty proxy-blr or plex-edge worktree; ALLOW_DIRTY=1 so deploying anyway"
  else
    die "dirty proxy-blr or plex-edge worktree; commit, discard, or rerun with ALLOW_DIRTY=1"
  fi
fi

# Sync the installed units from the repo copy. New unit versions apply next run.
if [[ -f "$REPO_DIR/proxy-blr/systemd/install.sh" ]]; then
  bash "$REPO_DIR/proxy-blr/systemd/install.sh" --if-changed \
    || log "WARNING: unit sync failed"
else
  log "WARNING: installer not found at $REPO_DIR/proxy-blr/systemd/install.sh"
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

# Hash of the Traefik config the container mounts (this proxy's traefik/ and
# the shared plex-edge/traefik/), to tell whether Traefik must be restarted.
traefik_config_hash() {
  local files
  files="$(find traefik ../plex-edge/traefik -type f -print0 | sort -z | xargs -0 sha256sum)" \
    || return 1
  sha256sum <<<"$files" | cut -d' ' -f1
}
TRAEFIK_STATE="${TRAEFIK_STATE:-/var/lib/proxy-blr-updater/traefik-config.sha256}"

docker compose pull --ignore-pull-failures --quiet \
  || log "WARNING: one or more image pulls failed; continuing"

# Which Traefik container runs before `up`, to tell afterwards whether `up`
# recreated it.
traefik_before="$(docker compose ps -aq traefik)"

# One up for the whole project so Compose honours depends_on/restart ordering.
if ! docker compose up -d --remove-orphans; then
  # Compose aborts the whole up when one container fails to start, leaving the
  # rest in Created. Retry each service on its own so one broken service cannot
  # take the host down. No --no-deps: each up also starts that service's
  # dependencies, so the loop order does not matter, and a service whose
  # dependency is broken (e.g. qbittorrent -> gluetun) is reported as failed too.
  log "WARNING: docker compose up failed; retrying each service separately"
  failed=()
  while read -r svc; do
    [[ -n "$svc" ]] || continue
    docker compose up -d "$svc" </dev/null || failed+=("$svc")
  done < <(docker compose config --services)
  # Still a failed run, so OnFailure= reports it to Uptime Kuma either way.
  if ((${#failed[@]})); then
    die "services failed to start: ${failed[*]}"
  fi
  die "docker compose up failed, but every service started on retry"
fi

# Traefik's file provider does not watch its subdirectories (see
# docker-compose.yaml), so a config change needs a restart. No SIGHUP: a
# SIGHUP that reaches Traefik before it has installed its handler kills it
# (exit 129), and `docker kill` marks the container as stopped by hand, so
# `unless-stopped` does not bring it back. That took proxy-blr down on
# 2026-11-24, when the HUP landed 0.3 s after a recreate.
#
# Restart only when the mounted config differs from what this Traefik loaded.
# A container that `up` just created started on the current files, so it only
# records the hash. The hash is kept across runs, so a run that failed before
# restarting is caught up by the next one.
traefik_after="$(docker compose ps -aq traefik)"
traefik_config="$(traefik_config_hash)" || die "cannot hash the traefik config"
traefik_loaded="$(cat "$TRAEFIK_STATE" 2>/dev/null || true)"
if [[ -n "$traefik_before" && "$traefik_after" == "$traefik_before" \
      && "$traefik_config" != "$traefik_loaded" ]]; then
  log "traefik config changed; restarting traefik"
  docker compose restart traefik >/dev/null || die "could not restart traefik"
fi
mkdir -p "$(dirname "$TRAEFIK_STATE")"
printf '%s\n' "$traefik_config" >"$TRAEFIK_STATE"

# Fail the run if a service that should stay up is not running, so Uptime Kuma
# gets DOWN instead of UP. Wait first, to catch a container that dies right
# after it starts. Only containers with an always/unless-stopped restart policy
# are checked: one-shot jobs (restart: "no") may exit by design.
sleep 15
not_running=()
while read -r name policy status; do
  case "$policy" in always|unless-stopped) ;; *) continue ;; esac
  [[ "$status" == running ]] || not_running+=("${name#/} ($status)")
done < <(docker compose ps -aq | xargs -r docker inspect -f '{{.Name}} {{.HostConfig.RestartPolicy.Name}} {{.State.Status}}')
if ((${#not_running[@]})); then
  die "not running after deploy: ${not_running[*]}"
fi

# Remove every image no container uses (running or stopped), unused networks
# and build cache. Pinned tags are never "dangling", so a plain `image prune`
# kept every superseded version forever and filled the disk. Rollback does not
# need the old image locally: reverting the tag and redeploying pulls it again.
# Containers are never removed here: `docker system prune` used to delete
# stopped ones, which erased a container that had just died (and its logs) and
# its image with it. Volumes are not touched.
docker image prune -af >/dev/null
docker network prune -f >/dev/null
docker builder prune -af >/dev/null

log "deploy complete"

# Heartbeat for the Uptime Kuma push monitor (failures: notify-failure.sh).
NOTIFY_CONFIG="${NOTIFY_CONFIG:-/etc/default/compose-updater}"
if [[ -r "$NOTIFY_CONFIG" ]]; then
  # shellcheck source=/dev/null
  . "$NOTIFY_CONFIG"
  if [[ -n "${KUMA_PUSH_URL:-}" ]]; then
    msg="deployed $(as_owner git -C "$REPO_DIR" rev-parse --short HEAD)"
    curl -fsS --max-time 20 --retry 6 --retry-delay 5 --retry-connrefused -G "$KUMA_PUSH_URL" --data-urlencode status=up \
      --data-urlencode "msg=$msg" >/dev/null || log "WARNING: Kuma push failed"
  fi
fi
