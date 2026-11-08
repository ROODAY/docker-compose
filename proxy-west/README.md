# proxy-west

DigitalOcean droplet `137.184.32.90` (SFO, 1 vCPU / 1 GB + 2 GB swap).

| Service | Host | Backend |
|---|---|---|
| Plex proxy | `plex-proxy.intimidator.rooday.com` | `https://plex.intimidator.rooday.com` |
| librespeed (basic auth) | `librespeed.plex-proxy.intimidator.rooday.com` | `librespeed` container |
| Uptime Kuma (primary) | `status.rooday.com` | `uptime-kuma`, inside the `tailscale` namespace |

Traefik reads every route from `traefik/dynamic.yml` (no docker socket) and
gets Let's Encrypt certificates by HTTP-01 (keep the DNS records grey-clouded). Access logs are JSON with
`RequestPath` dropped, so Plex tokens in query strings are never written.

Uptime Kuma shares the `tailscale` container's network namespace, so it can
monitor `*.ts.rooday.com`. The node is tagged `tag:monitor`.

## First-time setup

```bash
git clone https://github.com/ROODAY/docker-compose.git ~/docker-compose
cd ~/docker-compose/proxy-west
cp .env.example .env && chmod 600 .env && nano .env
sudo bash migrate.sh             # rolls back by itself if anything fails
# then the daily auto-deploy timer: see systemd/README.md
docker logs tailscale 2>&1 | grep -i login.tailscale   # open the URL to join
```

Then in the Tailscale admin console: disable key expiry for `proxy-west`.

Tailscale ACL (the tag must be in `tagOwners` before the node logs in):

```jsonc
"tagOwners": { "tag:monitor": ["autogroup:admin"] },
"grants": [
  // Kuma may reach the homelab Traefik-ts nodes on HTTPS, nothing else.
  { "src": ["tag:monitor"], "dst": ["tag:container"], "ip": ["tcp:443"] }
]
```

Make sure no broader rule (such as the default allow-all) also matches `tag:monitor`.

## Backups

`duplicacy/install.sh` installs Duplicacy, duplicacy-util and a daily
`proxy-west-backup.timer`. The `pre-backup` hook writes a consistent copy of
Kuma's SQLite DB to `db-dumps/kuma.db`; `filters` excludes the live DB files.
Everything else in this folder (`.env`, `data/`) is backed up, so use an
encrypted storage (`duplicacy init -e`). Run the script for the next step.

## Rollback

`sudo bash migrate.sh --rollback` restores nginx, `librespeed.service`,
certbot and the old `/opt/uptime-kuma` container (on pre-migration data).
