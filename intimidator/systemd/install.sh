#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/lib/intimidator-updater}"
UNIT_DIR="${UNIT_DIR:-/etc/systemd/system}"
TIMER_UNIT="intimidator-update.timer"

MANIFEST="$INSTALL_DIR/manifest.sha256"
SRC_SCRIPT="$SCRIPT_DIR/update-containers.sh"
SRC_SERVICE="$SCRIPT_DIR/intimidator-update.service"
SRC_TIMER="$SCRIPT_DIR/intimidator-update.timer"

log() { printf '%s\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
hash_file() {
  local hash
  hash="$(sha256sum "$1" | cut -d' ' -f1)"
  [[ -n "$hash" ]] || { echo "cannot hash $1" >&2; return 1; }
  printf '%s\n' "$hash"
}

for src_file in "$SRC_SCRIPT" "$SRC_SERVICE" "$SRC_TIMER"; do
  [[ -f "$src_file" ]] || die "missing source file: $src_file"
done

repo_manifest() {
  local script_hash service_hash timer_hash
  script_hash="$(hash_file "$SRC_SCRIPT")" || return 1
  service_hash="$(hash_file "$SRC_SERVICE")" || return 1
  timer_hash="$(hash_file "$SRC_TIMER")" || return 1
  printf '%s  %s\n' "$script_hash" "$INSTALL_DIR/update-containers.sh"
  printf '%s  %s\n' "$service_hash" "$UNIT_DIR/intimidator-update.service"
  printf '%s  %s\n' "$timer_hash" "$UNIT_DIR/intimidator-update.timer"
}
repo_version() { repo_manifest | sha256sum | cut -c1-12; }
installed_version() {
  if [[ -f "$MANIFEST" ]]; then sha256sum "$MANIFEST" | cut -c1-12; else echo "none"; fi
}
timer_enabled() {
  command -v systemctl >/dev/null || return 0
  systemctl is-enabled --quiet "$TIMER_UNIT" 2>/dev/null
}

# Returns 0 when written, 1 when already current, 2 on failure. Called from
# condition context, where bash would suppress set -e, so failures are explicit.
install_one() {
  local src="$1" dest="$2" mode="$3" tmp
  if [[ -f "$dest" ]] && cmp -s "$src" "$dest"; then
    return 1
  fi
  mkdir -p "$(dirname "$dest")" || return 2
  tmp="$dest.tmp.$$"
  install -m "$mode" "$src" "$tmp" || { rm -f "$tmp"; return 2; }
  mv -f "$tmp" "$dest" || { rm -f "$tmp"; return 2; }
  return 0
}

mode=install
case "${1:-}" in
  "") ;;
  --check|--if-changed|--uninstall) mode="$1" ;;
  *) echo "usage: $0 [--check|--if-changed|--uninstall]" >&2; exit 2 ;;
esac

if [[ "$mode" == "--check" ]]; then
  drift=0
  for pair in "$SRC_SCRIPT|$INSTALL_DIR/update-containers.sh" \
              "$SRC_SERVICE|$UNIT_DIR/intimidator-update.service" \
              "$SRC_TIMER|$UNIT_DIR/intimidator-update.timer"; do
    src="${pair%%|*}"
    dest="${pair##*|}"
    if [[ ! -f "$dest" ]] || ! cmp -s "$src" "$dest"; then
      drift=1
    fi
  done
  if [[ "$drift" -eq 0 ]] && timer_enabled; then
    log "up to date (v$(repo_version))"
    exit 0
  fi
  repo_v="$(repo_version)"
  installed_v="$(installed_version)"
  if [[ "$installed_v" == "$repo_v" ]]; then
    log "update available: installed files differ from the repo (v$repo_v)"
  else
    log "update available: installed v$installed_v, repo v$repo_v"
  fi
  exit 1
fi

if [[ "$(id -u)" -ne 0 && "${SKIP_ROOT_CHECK:-0}" != "1" ]]; then
  echo "run as root: sudo $0" >&2
  exit 1
fi

if [[ "$mode" == "--uninstall" ]]; then
  systemctl disable --now "$TIMER_UNIT" 2>/dev/null || true
  rm -f "$UNIT_DIR/intimidator-update.service" "$UNIT_DIR/intimidator-update.timer"
  rm -rf "$INSTALL_DIR"
  systemctl daemon-reload 2>/dev/null || true
  log "uninstalled"
  exit 0
fi

changed=0
install_artifact() {
  local src="$1" dest="$2" mode="$3" status
  status=0
  install_one "$src" "$dest" "$mode" || status=$?
  case "$status" in
    0) changed=1 ;;
    1) ;;
    *) die "failed to install $dest" ;;
  esac
}
install_artifact "$SRC_SCRIPT" "$INSTALL_DIR/update-containers.sh" 0755
install_artifact "$SRC_SERVICE" "$UNIT_DIR/intimidator-update.service" 0644
install_artifact "$SRC_TIMER" "$UNIT_DIR/intimidator-update.timer" 0644

new_manifest="$MANIFEST.tmp.$$"
repo_manifest >"$new_manifest" \
  || { rm -f "$new_manifest"; die "cannot compute manifest"; }
if [[ ! -f "$MANIFEST" ]] || ! cmp -s "$new_manifest" "$MANIFEST"; then
  mv -f "$new_manifest" "$MANIFEST" || die "cannot write $MANIFEST"
  changed=1
else
  rm -f "$new_manifest"
fi

if [[ "$changed" -eq 0 ]] && timer_enabled; then
  [[ "$mode" == "--if-changed" ]] || log "already installed (v$(repo_version)); nothing to do"
  exit 0
fi

systemctl daemon-reload
systemctl enable --now "$TIMER_UNIT"
log "installed and enabled $TIMER_UNIT (v$(repo_version))"
