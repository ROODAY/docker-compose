#!/usr/bin/env bash
# Report a failed deploy to Uptime Kuma. Started by the deploy service's
# OnFailure= unit, so it runs only after the deploy has already failed.
#
# The droplets have no MTA, so instead of email this marks the deploy's Kuma
# push monitor DOWN and Kuma alerts through its own notifications. A good run
# pushes UP (end of update-containers.sh), so a timer that stops firing also
# alerts once the push monitor's heartbeat interval passes.
#
# The push URL is host-local, never in the repo:
#   /etc/default/compose-updater
#     KUMA_PUSH_URL="https://status.rooday.com/api/push/<token>"
set -uo pipefail

UNIT="${1:?usage: notify-failure.sh <failed unit>}"
CONFIG="${NOTIFY_CONFIG:-/etc/default/compose-updater}"

log() { printf '%s\n' "$*" >&2; }

if [[ ! -r "$CONFIG" ]]; then
  log "no $CONFIG; not reporting the failure"
  exit 0
fi
# shellcheck source=/dev/null
. "$CONFIG"
if [[ -z "${KUMA_PUSH_URL:-}" ]]; then
  log "KUMA_PUSH_URL is unset in $CONFIG; not reporting the failure"
  exit 0
fi

host="$(hostname -s 2>/dev/null || hostname)"
# The failed run's last ERROR line (every line it logged carries its invocation id).
invocation="$(systemctl show -p InvocationID --value "$UNIT" 2>/dev/null || true)"
if [[ -n "$invocation" ]]; then
  reason="$(journalctl --no-pager -o cat "_SYSTEMD_INVOCATION_ID=$invocation" 2>/dev/null | grep 'ERROR' | tail -n1)"
fi
reason="${reason:-see journalctl -u $UNIT}"

curl -fsS --max-time 20 -G "$KUMA_PUSH_URL" \
  --data-urlencode status=down \
  --data-urlencode "msg=$UNIT failed on $host: ${reason:0:200}" >/dev/null \
  || { log "Kuma push failed"; exit 1; }
log "reported failure to Uptime Kuma"
