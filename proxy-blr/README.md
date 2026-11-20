# proxy-blr

DigitalOcean droplet in BLR1 (Bangalore, 1 vCPU / 1 GB). Plex edge for
clients in South Asia. It relays both Plex servers through their home proxies
(see `../plex-edge/README.md`). BLR1 reaches both US coasts at about 210 ms; it
goes via Europe, not the Pacific.

| Service | Host | Backend |
|---|---|---|
| Plex edge | `plex-proxy.intimidator.rooday.com`, `plex-proxy.engager.rooday.com` (when Route 53 picks this edge) | relay to `proxy-west` / `proxy-east` |
| librespeed (basic auth) | `librespeed.proxy-blr.rooday.com` | `librespeed` container |

There is no Uptime Kuma and no backup. The only state is the ACME
certificates and the librespeed htpasswd, so rebuild from scratch instead of
restoring.

## First-time setup

The droplet should be in the `Firewall` cloud firewall (22/80/443 in).
As `rooday`:

```bash
git clone https://github.com/ROODAY/docker-compose.git ~/docker-compose
cd ~/docker-compose
sudo install -m 644 plex-edge/sysctl/90-plex-edge.conf /etc/sysctl.d/
sudo install -m 644 plex-edge/sysctl/bbr.conf /etc/modules-load.d/
sudo modprobe tcp_bbr && sudo sysctl --system >/dev/null
cd proxy-blr
cp .env.example .env && chmod 600 .env && nano .env
mkdir -p data/traefik/letsencrypt data/librespeed
install -m 600 /dev/null data/traefik/letsencrypt/acme.json
# Traefik basicAuth reads only bcrypt, apr1 or SHA1 hashes (apt install apache2-utils).
htpasswd -B -c data/traefik/htpasswd-librespeed <user> && chmod 600 data/traefik/htpasswd-librespeed
docker compose up -d
# then the daily auto-deploy timer: see systemd/README.md
```

Then add it to DNS: the A records `proxy-blr.rooday.com` and
`librespeed.proxy-blr.rooday.com` (grey) in Cloudflare, and a Route 53 health
check and latency record (region `ap-south-2`). See `../plex-edge/README.md`.

## Retiring it

Full steps, including Uptime Kuma: `../plex-edge/SOP.md`, section 3.
IDs: droplet `619987115`, IP `168.144.65.133`, Route 53 health check
`25a1e5b6-2349-5102-09da-c59c39d3101c`, latency region `ap-south-2`. In Kuma,
the `proxy-blr` group holds "Librespeed (proxy-blr)" and "proxy-blr deploy".
