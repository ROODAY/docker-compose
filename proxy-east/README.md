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
mkdir -p data/traefik/letsencrypt data/uptime-kuma data/librespeed
install -m 600 /dev/null data/traefik/letsencrypt/acme.json
# Traefik basicAuth reads only bcrypt, apr1 or SHA1 hashes (apt install apache2-utils).
htpasswd -B -c data/traefik/htpasswd-librespeed <user> && chmod 600 data/traefik/htpasswd-librespeed
docker compose up -d
# then the daily auto-deploy timer: see systemd/README.md
```

## Backups

`duplicacy/install.sh` installs Duplicacy, duplicacy-util and a daily
`proxy-east-backup.timer`. The `pre-backup` hook writes a consistent copy of
Kuma's SQLite DB to `db-dumps/kuma.db`; `filters` excludes the live DB files.
Everything else in this folder (`.env`, `data/`) is backed up, so use an
encrypted storage (`duplicacy init -e`). Run the script for the next step.

## Restore from backup

To rebuild this droplet from B2 instead of starting fresh, clone the repo,
then from `~/docker-compose/proxy-east`:

```bash
sudo bash duplicacy/install.sh
sudo duplicacy init -e proxy-east b2://proxy-east     # B2 key ID, app key, storage password
sudo duplicacy set -key b2_id -value '<keyID>'
sudo duplicacy set -key b2_key -value '<applicationKey>'
sudo duplicacy set -key password -value '<storage-password>'
sudo chmod 600 .duplicacy/preferences
sudo duplicacy list                        # pick the revision
sudo duplicacy restore -r <revision> -overwrite
# The live kuma.db is excluded from backups; the pre-backup dump replaces it.
sudo cp db-dumps/kuma.db data/uptime-kuma/kuma.db
docker compose up -d
```

Then recreate `/etc/duplicacy-util/` (see Backups) and re-run `install.sh`.
The pre-migration host setup (nginx, certbot, `/opt/uptime-kuma`) was removed
on 2026-11-08; it is archived as `data/legacy-*.tgz` in that day's backup
revisions (kept until prune drops them, about a year).
