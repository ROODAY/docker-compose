# proxy-east

DigitalOcean droplet `104.248.10.1` (NYC, 1 vCPU / 1 GB + 2 GB swap).

| Service | Host | Backend |
|---|---|---|
| Plex proxy | `plex-proxy.engager.rooday.com` | `https://plex.engager.rooday.com` |
| librespeed (basic auth) | `librespeed.plex-proxy.engager.rooday.com` | `librespeed` container |
| Uptime Kuma (backup) | `status2.rooday.com` | `uptime-kuma` container; only monitors `status.rooday.com` |

Traefik reads every route from `traefik/dynamic.yml` (no docker socket) and
gets Let's Encrypt certificates by Cloudflare DNS-01. `status*` may be
orange-clouded; keep the Plex and librespeed records grey. Access logs are JSON with
`RequestPath` dropped, so Plex tokens in query strings are never written.

## First-time setup

```bash
git clone https://github.com/ROODAY/docker-compose.git ~/docker-compose
cd ~/docker-compose/proxy-east
cp .env.example .env && chmod 600 .env && nano .env
sudo bash migrate.sh             # rolls back by itself if anything fails
# then the daily auto-deploy timer: see systemd/README.md
```

## Backups

`duplicacy/install.sh` installs Duplicacy, duplicacy-util and a daily
`proxy-east-backup.timer`. The `pre-backup` hook writes a consistent copy of
Kuma's SQLite DB to `db-dumps/kuma.db`; `filters` excludes the live DB files.
Everything else in this folder (`.env`, `data/`) is backed up, so use an
encrypted storage (`duplicacy init -e`). Run the script for the next step.

## Rollback

`sudo bash migrate.sh --rollback` restores nginx, `librespeed.service`,
certbot and the old `/opt/uptime-kuma` container (on pre-migration data).
