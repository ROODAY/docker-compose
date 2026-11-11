#!/usr/bin/env bash
# Installs Duplicacy + duplicacy-util and a daily backup timer for this folder.
# Safe to re-run. You provide the storage and duplicacy-util config:
#
#   1. sudo bash duplicacy/install.sh          # binaries, sqlite3, units
#   2. cd <this folder> && sudo duplicacy init -e <snapshot-id> <storage-url>
#      (plus `sudo duplicacy set -key ... -value ...` for storage credentials)
#   3. put duplicacy-util.yaml and <name>.yaml in /etc/duplicacy-util/
#   4. sudo bash duplicacy/install.sh          # installs filters/script, enables timer
#
# <name> is this folder's name (proxy-west / proxy-east).
set -euo pipefail

DUPLICACY_VERSION=3.3.0
DUPLICACY_SHA256=a2ac4db7018633b116506e081a029dd6635e9619cf24b85c33144640613416ee
# ROODAY's fork: upstream 1.5 rebuilt with a newer gomail. Upstream's binary
# sends a malformed Content-Type that Amazon SES rejects (554). The fork's
# binary reports "Version: <dev>", so it is checked by hash, not -version.
DUTIL_VERSION=1.5.1
DUTIL_SHA256=f6a61fbad7801af60968d80c4c5fb69bcf7f1ddbaa65e696b709ecbb7b0c3a08
CONF_DIR=/etc/duplicacy-util

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
NAME="$(basename "$REPO_ROOT")"
UNIT="$NAME-backup"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ "$(id -u)" -eq 0 ]] || die "run with sudo"

fetch() { # url sha256 dest
  local tmp; tmp="$(mktemp)"
  curl -fsSL "$1" -o "$tmp"
  echo "$2  $tmp" | sha256sum -c --quiet - || { rm -f "$tmp"; die "checksum mismatch for $1"; }
  install -m 0755 "$tmp" "$3"; rm -f "$tmp"
}

command -v sqlite3 >/dev/null || { apt-get update -qq; apt-get install -y -qq sqlite3; }

if ! /usr/local/bin/duplicacy 2>/dev/null | grep -q "$DUPLICACY_VERSION"; then
  fetch "https://github.com/gilbertchen/duplicacy/releases/download/v$DUPLICACY_VERSION/duplicacy_linux_x64_$DUPLICACY_VERSION" \
    "$DUPLICACY_SHA256" /usr/local/bin/duplicacy
fi
if ! echo "$DUTIL_SHA256  /usr/local/bin/duplicacy-util" | sha256sum -c --quiet - >/dev/null 2>&1; then
  fetch "https://github.com/ROODAY/duplicacy-util/releases/download/v$DUTIL_VERSION/duplicacy-util_linux_x64_v$DUTIL_VERSION" \
    "$DUTIL_SHA256" /usr/local/bin/duplicacy-util
fi
echo "duplicacy $DUPLICACY_VERSION, duplicacy-util $DUTIL_VERSION installed"

install -d -m 700 "$CONF_DIR"

cat >"/etc/systemd/system/$UNIT.service" <<EOF
[Unit]
Description=Duplicacy backup of $REPO_ROOT
Wants=network-online.target
After=network-online.target docker.service

[Service]
Type=oneshot
Environment=HOME=/root
WorkingDirectory=$REPO_ROOT
ExecStart=/usr/local/bin/duplicacy-util -sd $CONF_DIR -f $NAME -a -q
# duplicacy-util exits 6200 ("already running"), seen by systemd as 6200 % 256.
SuccessExitStatus=56
# Heartbeat for an Uptime Kuma push monitor; runs only after a successful
# backup, so a failed or missed backup alerts once the heartbeat lapses.
EnvironmentFile=-/etc/default/compose-updater
ExecStartPost=-/bin/sh -c 'test -z "\${BACKUP_PUSH_URL}" || curl -fsS -m 20 --retry 6 --retry-delay 5 --retry-connrefused -G "\${BACKUP_PUSH_URL}" --data-urlencode status=up --data-urlencode "msg=$NAME backup OK" >/dev/null || echo "WARNING: Kuma backup push failed" >&2'
Nice=10
IOSchedulingClass=idle
TimeoutStartSec=2h
EOF
cat >"/etc/systemd/system/$UNIT.timer" <<EOF
[Unit]
Description=Daily Duplicacy backup of $REPO_ROOT

[Timer]
OnCalendar=*-*-* 03:30:00
RandomizedDelaySec=30m
Persistent=true
Unit=$UNIT.service

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload

if [[ ! -f "$REPO_ROOT/.duplicacy/preferences" ]]; then
  cat <<EOF

Next: initialise the repository, then re-run this script.
  cd $REPO_ROOT && sudo duplicacy init -e $NAME <storage-url>
EOF
  exit 0
fi

install -d "$REPO_ROOT/.duplicacy/scripts"
install -m 0644 "$SCRIPT_DIR/filters" "$REPO_ROOT/.duplicacy/filters"
install -m 0755 "$SCRIPT_DIR/pre-backup" "$REPO_ROOT/.duplicacy/scripts/pre-backup"
echo "installed .duplicacy/filters and .duplicacy/scripts/pre-backup"

if [[ ! -f "$CONF_DIR/$NAME.yaml" ]]; then
  cat <<EOF

Next: add $CONF_DIR/duplicacy-util.yaml and $CONF_DIR/$NAME.yaml
(repository: $REPO_ROOT), then re-run this script to enable the timer.
EOF
  exit 0
fi

systemctl enable --now "$UNIT.timer"
echo "enabled $UNIT.timer; run one now with: sudo systemctl start $UNIT.service"
