#!/usr/bin/env bash
set -euo pipefail

unit="intimidator-update.service"

if ! systemctl list-unit-files "$unit" >/dev/null 2>&1; then
  echo "$unit is not installed." >&2
  echo "Install it first: sudo bash intimidator/systemd/install.sh" >&2
  exit 1
fi

echo "Starting $unit..."
status=0
# Type=oneshot, so systemctl start returns when the deploy finishes.
sudo systemctl start "$unit" || status=$?

echo
echo "Last log lines:"
sudo journalctl -u "$unit" --no-pager -n 20 || true

exit "$status"
