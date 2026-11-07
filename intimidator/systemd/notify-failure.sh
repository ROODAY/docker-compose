#!/usr/bin/env bash
# Email the journal of a failed deploy run. Started by the deploy service's
# OnFailure= unit, so it runs only after the deploy has already failed.
#
# Recipient and sender are host-local, never in the repo:
#   /etc/default/compose-updater
#     NOTIFY_FROM="Name <sender@verified.domain>"
#     NOTIFY_TO="Name <you@example.com>"
# Delivery goes through the local MTA (postfix relaying via SES).
set -uo pipefail

UNIT="${1:?usage: notify-failure.sh <failed unit>}"
CONFIG="${NOTIFY_CONFIG:-/etc/default/compose-updater}"
SENDMAIL="${SENDMAIL:-/usr/sbin/sendmail}"
LINES="${NOTIFY_LINES:-80}"

log() { printf '%s\n' "$*" >&2; }

if [[ ! -r "$CONFIG" ]]; then
  log "no $CONFIG; not sending a failure email"
  exit 0
fi
# shellcheck source=/dev/null
. "$CONFIG"
if [[ -z "${NOTIFY_TO:-}" || -z "${NOTIFY_FROM:-}" ]]; then
  log "NOTIFY_TO or NOTIFY_FROM is unset in $CONFIG; not sending a failure email"
  exit 0
fi
[[ -x "$SENDMAIL" ]] || { log "$SENDMAIL not found; cannot send the failure email"; exit 1; }

host="$(hostname -s 2>/dev/null || hostname)"
# Envelope sender: the bare address inside <...>, or the whole value if bare.
envelope="$(sed -E 's/^.*<([^>]+)>.*$/\1/' <<<"$NOTIFY_FROM")"

# Only the failed run's output: every line its processes logged carries the
# run's invocation id. Fall back to the unit's last lines if that is missing.
invocation="$(systemctl show -p InvocationID --value "$UNIT" 2>/dev/null || true)"
if [[ -n "$invocation" ]]; then
  journal="$(journalctl --no-pager -o short-iso "_SYSTEMD_INVOCATION_ID=$invocation" 2>&1 | tail -n "$LINES")"
else
  journal="$(journalctl --no-pager -o short-iso -u "$UNIT" -n "$LINES" 2>&1)"
fi

if command -v docker >/dev/null; then
  running="$(docker ps -q 2>/dev/null | wc -l)"
  stopped="$(docker ps -a --filter status=created --filter status=exited --filter status=dead \
    --format '{{.Names}}\t{{.Status}}' 2>&1)"
else
  running="?"
  stopped="docker CLI not found"
fi

{
  printf 'From: %s\n' "$NOTIFY_FROM"
  printf 'To: %s\n' "$NOTIFY_TO"
  printf 'Subject: [%s] %s failed\n' "$host" "$UNIT"
  printf 'Content-Type: text/plain; charset=UTF-8\n'
  printf '\n'
  printf '%s failed on %s at %s.\n\n' "$UNIT" "$host" "$(date -Is)"
  printf 'Running containers: %s\n\n' "$running"
  printf 'Not running (one-shot jobs such as kometa or recyclarr exit by design):\n%s\n\n' "${stopped:-(none)}"
  printf 'Last %s lines of the failed run:\n%s\n\n' "$LINES" "$journal"
  printf 'Full log: journalctl -u %s -b\n' "$UNIT"
} | "$SENDMAIL" -t -f "$envelope"
