# proxy-blr deploy

Same design as `intimidator/systemd` (read that README for the details): git
is the source of truth, Renovate opens image-update PRs, and this timer
deploys whatever lands on `main`.

Differences on the droplets:

- **Schedule:** daily at 08:30 UTC (+ up to 30 min jitter). proxy-east runs at
  09:30 and proxy-west at 10:30, so no two proxies redeploy at once.
- **Alerts:** there is no MTA, so failures go to Uptime Kuma, not email.
  A failed run marks a push monitor DOWN with the error line; a good run
  pushes UP. Set the push monitor's heartbeat interval to ~25h so a timer
  that stops firing alerts too.

## Install

```bash
sudo tee /etc/default/compose-updater >/dev/null <<'EOF'
KUMA_PUSH_URL="https://status.rooday.com/api/push/<deploy token>"
EOF
sudo chmod 600 /etc/default/compose-updater
sudo bash ./proxy-blr/systemd/install.sh
bash ./proxy-blr/update-now.sh      # one run now, prints the journal
```

Test the failure path: `sudo systemctl start proxy-blr-update-notify.service`.

## Editing on the droplet

A dirty `proxy-blr/` or `plex-edge/` checkout is refused
(`ERROR: dirty proxy-blr or plex-edge worktree`).
Commit and push from the droplet (or anywhere) and the next run deploys it.

Uninstall: `sudo bash ./proxy-blr/systemd/install.sh --uninstall`.
