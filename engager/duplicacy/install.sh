#!/usr/bin/env bash
# Runs this host's whole-system Duplicacy backup (repository root /) from a
# daily systemd timer. Safe to re-run.
#
#   sudo bash <name>/duplicacy/install.sh
#
# Needs, already on the host: /usr/local/bin/duplicacy, the ROODAY fork of
# /usr/local/bin/duplicacy-util, an initialised /.duplicacy (storage
# "backblaze"), and /etc/duplicacy-util/duplicacy-util.yaml (from
# duplicacy-util.yaml.example). BACKUP_PUSH_URL in /etc/default/compose-updater
# feeds the Kuma push monitor.
set -euo pipefail

CONF_DIR=/etc/duplicacy-util

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
NAME="$(basename "$(dirname "$SCRIPT_DIR")")"
UNIT="$NAME-backup"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ "$(id -u)" -eq 0 ]] || die "run with sudo"

for b in duplicacy duplicacy-util; do
  [[ -x /usr/local/bin/$b ]] || die "/usr/local/bin/$b is missing"
done
[[ -f /.duplicacy/preferences ]] || die "/.duplicacy is not initialised"

install -d -m 700 "$CONF_DIR"
[[ -f "$CONF_DIR/duplicacy-util.yaml" ]] \
  || die "no $CONF_DIR/duplicacy-util.yaml; create it (chmod 600) from $SCRIPT_DIR/duplicacy-util.yaml.example"
install -m 600 "$SCRIPT_DIR/$NAME.yaml" "$CONF_DIR/$NAME.yaml"
install -m 644 "$SCRIPT_DIR/filters" /.duplicacy/filters
echo "installed $CONF_DIR/$NAME.yaml and /.duplicacy/filters"

cat >"/etc/systemd/system/$UNIT.service" <<UNIT_EOF
[Unit]
Description=Duplicacy backup of $NAME (/)
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
Environment=HOME=/root
WorkingDirectory=/
ExecStart=/usr/local/bin/duplicacy-util -sd $CONF_DIR -f $NAME -a -q
# duplicacy-util exits 6200 ("already running"), seen by systemd as 6200 % 256.
SuccessExitStatus=56
# Heartbeat for an Uptime Kuma push monitor; runs only after a successful
# backup, so a failed or missed backup alerts once the heartbeat lapses.
EnvironmentFile=-/etc/default/compose-updater
ExecStartPost=-/bin/sh -c 'test -z "\${BACKUP_PUSH_URL}" || curl -fsS -m 20 "\${BACKUP_PUSH_URL}?status=up&msg=OK" >/dev/null'
Nice=10
IOSchedulingClass=idle
TimeoutStartSec=12h
UNIT_EOF
# 02:00 keeps the backup clear of the deploy timer (intimidator 05:00,
# engager 04:30), so containers are not restarted mid-backup.
cat >"/etc/systemd/system/$UNIT.timer" <<UNIT_EOF
[Unit]
Description=Daily Duplicacy backup of $NAME

[Timer]
OnCalendar=*-*-* 02:00:00
RandomizedDelaySec=30m
Persistent=true
Unit=$UNIT.service

[Install]
WantedBy=timers.target
UNIT_EOF
systemctl daemon-reload
systemctl enable --now "$UNIT.timer"
echo "enabled $UNIT.timer; run one now with: sudo systemctl start $UNIT.service"
