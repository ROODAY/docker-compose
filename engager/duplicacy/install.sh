#!/usr/bin/env bash
# Runs this host's whole-system Duplicacy backup (repository root /) from a
# systemd timer instead of root's crontab. Safe to re-run.
#
#   sudo bash <name>/duplicacy/install.sh
#
# Needs, already on the host: /usr/local/bin/duplicacy, the ROODAY fork of
# /usr/local/bin/duplicacy-util, an initialised /.duplicacy (storage
# "backblaze"), and /etc/duplicacy-util/duplicacy-util.yaml (copied once from
# /home/rooday/.duplicacy-util if it is missing). BACKUP_PUSH_URL in
# /etc/default/compose-updater feeds the Kuma push monitor.
set -euo pipefail

CONF_DIR=/etc/duplicacy-util
OLD_CONF_DIR=/home/rooday/.duplicacy-util

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
NAME="$(basename "$(dirname "$SCRIPT_DIR")")"
UNIT="$NAME-backup"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ "$(id -u)" -eq 0 ]] || die "run with sudo"

for b in duplicacy duplicacy-util; do
  [[ -x /usr/local/bin/$b ]] || die "/usr/local/bin/$b is missing"
done
[[ -f /.duplicacy/preferences ]] || die "/.duplicacy is not initialised"

# Two schedulers would run the backup twice; the cron entry must go first.
if crontab -l 2>/dev/null | grep -q '^[^#]*duplicacy-util'; then
  die "root's crontab still runs duplicacy-util. Copy its push URL into
  /etc/default/compose-updater as BACKUP_PUSH_URL=\"https://status.rooday.com/api/push/<token>\"
  (no ?status=... part), then delete the line with: sudo crontab -e"
fi

install -d -m 700 "$CONF_DIR"
if [[ ! -f "$CONF_DIR/duplicacy-util.yaml" ]]; then
  [[ -f "$OLD_CONF_DIR/duplicacy-util.yaml" ]] \
    || die "no $CONF_DIR/duplicacy-util.yaml; create it from $SCRIPT_DIR/duplicacy-util.yaml.example"
  install -m 600 "$OLD_CONF_DIR/duplicacy-util.yaml" "$CONF_DIR/duplicacy-util.yaml"
  echo "copied duplicacy-util.yaml from $OLD_CONF_DIR"
fi
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
echo "once a timer run has succeeded, $OLD_CONF_DIR can be deleted"
