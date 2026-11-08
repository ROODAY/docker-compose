# proxy-west

DigitalOcean droplet `137.184.32.90` (SFO, 1 vCPU / 1 GB + 2 GB swap).

| Service | Host | Backend |
|---|---|---|
| Plex proxy | `plex-proxy.intimidator.rooday.com` | `https://plex.intimidator.rooday.com` |
| librespeed (basic auth) | `librespeed.plex-proxy.intimidator.rooday.com` | `librespeed` container |
| Uptime Kuma (primary) | `status.rooday.com` | `uptime-kuma`, inside the `tailscale` namespace |

Traefik reads every route from `traefik/dynamic.yml` (no docker socket) and
gets Let's Encrypt certificates by Cloudflare DNS-01. `status*` may be
orange-clouded; keep the Plex and librespeed records grey. Access logs are JSON with
`RequestPath` dropped, so Plex tokens in query strings are never written.

Uptime Kuma shares the `tailscale` container's network namespace, so it can
monitor `*.ts.rooday.com`. The node is tagged `tag:monitor`.

## First-time setup

```bash
git clone https://github.com/ROODAY/docker-compose.git ~/docker-compose
cd ~/docker-compose/proxy-west
cp .env.example .env && chmod 600 .env && nano .env
mkdir -p data/traefik/letsencrypt data/uptime-kuma data/librespeed
install -m 600 /dev/null data/traefik/letsencrypt/acme.json
# Traefik basicAuth reads only bcrypt, apr1 or SHA1 hashes (apt install apache2-utils).
htpasswd -B -c data/traefik/htpasswd-librespeed <user> && chmod 600 data/traefik/htpasswd-librespeed
docker compose up -d
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

## Restore from backup

To rebuild this droplet from B2 instead of starting fresh, clone the repo,
then from `~/docker-compose/proxy-west`:

```bash
sudo bash duplicacy/install.sh
sudo duplicacy init -e proxy-west b2://proxy-west     # B2 key ID, app key, storage password
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
