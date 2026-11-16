# plex-edge

A small Plex CDN: clients reach their nearest proxy, and traffic to a Plex
server in another region travels between DigitalOcean droplets instead of
over residential ISP paths. Modelled on
[brettpetch/plex-cdn](https://github.com/brettpetch/plex-cdn), plus a relay hop
to each server's home proxy.

```
Seattle  -> proxy-west ------------------> intimidator (WA)
Seattle  -> proxy-west -> proxy-east ----> engager (MA)
India    -> proxy-blr  -> proxy-east ----> engager
India    -> proxy-blr  -> proxy-west ----> intimidator
```

## How it works

**DNS.** `cdn.rooday.com` is delegated from Cloudflare to a Route 53 hosted
zone (profile `route53`, IAM user `route53-dns`, Route 53 permissions only).
There, `edge.cdn.rooday.com` has one latency-based A record per proxy, each tied to a
TCP/443 health check, with TTL 60. Route 53 answers with the healthy proxy closest to the
client's resolver (or the client subnet, when the resolver sends ECS).

| Proxy | IP | Route 53 region | Health check |
|---|---|---|---|
| proxy-west (SFO3) | 137.184.32.90 | us-west-1 | `09a1e5a7-636e-5102-09c4-f5f30b10a302` |
| proxy-east (NYC3) | 104.248.10.1 | us-east-1 | `51a1e5a7-6cd3-5102-09ce-ca6d7a595252` |
| proxy-blr (BLR1) | see proxy-blr/README.md | ap-south-2 | see proxy-blr/README.md |

The names Plex advertises, `plex-proxy.<server>.rooday.com`, are grey CNAMEs
to `edge.cdn.rooday.com` in Cloudflare, so the Plex settings never change.
Each proxy also has a fixed, non-steered A record, `<proxy>.rooday.com`, for
relaying. A relay cannot use the plex-proxy name, because from inside a proxy
that name resolves to the proxy itself.

**Routing.** `traefik/plex.yml` is shared by every proxy. Each proxy's
compose file mounts it and sets `PROXY_NAME`. It maps each Plex server to its home
proxy. Every proxy serves every plex-proxy name and does one of two things:

- If it is the server's home proxy, it forwards to the origin,
  `https://plex.<server>.rooday.com`.
- If not, it relays to `https://<home>.rooday.com`, keeping the Host header and SNI.
  The home proxy then takes the first branch. If the home proxy fails its
  `/identity` health check, the request goes to the origin directly.

Relays use HTTP/1.1 (`disableHTTP2`), so each stream gets its own TCP connection across
the long hop.

**TCP tuning.** `sysctl/` switches the proxies to BBR with larger socket
buffers. Measured on 2026-11-16, one stream from a home server through its
coast's DigitalOcean region to BLR1:

| | engager | intimidator |
|---|---|---|
| direct, residential -> BLR | 27-31 Mbit/s | 102-117 Mbit/s |
| via relay, Ubuntu defaults (cubic) | 94 Mbit/s | 96 Mbit/s |
| via relay, this tuning (BBR) | 316 Mbit/s | 131 Mbit/s |

Install the tuning on every proxy (once; it persists across reboots):

```bash
cd ~/docker-compose
sudo install -m 644 plex-edge/sysctl/90-plex-edge.conf /etc/sysctl.d/
sudo install -m 644 plex-edge/sysctl/bbr.conf /etc/modules-load.d/
sudo modprobe tcp_bbr && sudo sysctl --system >/dev/null
sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc   # bbr, fq
```

## Deploying changes

The file provider loads `local/` (the proxy's own `traefik/`) and `plex-edge/`
as subdirectories, but Traefik only watches the top directory. The daily
deploy (`<proxy>/systemd/update-containers.sh`) therefore sends Traefik a SIGHUP after
`docker compose up`. After a manual edit on a droplet, run
`docker kill -s HUP traefik`.

## Checks

```bash
# Which edge does DNS give me?
nslookup edge.cdn.rooday.com
# Exercise one edge on purpose (here: west -> east -> engager):
curl -s --resolve plex-proxy.engager.rooday.com:443:137.184.32.90 \
  https://plex-proxy.engager.rooday.com/identity
# Route 53 health:
aws --profile route53 route53 get-health-check-status --health-check-id <id>
```

## Adding a proxy

1. Copy `proxy-blr/` to `proxy-<name>/` and replace `proxy-blr` throughout, including in the
   systemd unit file names. Set `PROXY_NAME`, librespeed's `TZ` and host, and a timer slot
   that no other proxy uses.
2. Add it to `managerFilePatterns` in `renovate.json`.
3. Create the droplet and add it to the `Firewall` cloud firewall. Then add the grey A record
   `proxy-<name>.rooday.com` in Cloudflare, and a Route 53 TCP/443 health check plus a latency
   record for `edge.cdn.rooday.com` (pick the closest AWS region).
4. Install the sysctl tuning and follow `proxy-blr/README.md` for first-time setup.

To retire a proxy, delete its latency record first. Wait a few minutes for the
60-second TTL, then destroy the droplet and remove its health check and A record.

## Adding a Plex server

Add `"<server>" "<home proxy>"` to `$homes` in `traefik/plex.yml`. Point
`plex-proxy.<server>.rooday.com` (grey CNAME) at `edge.cdn.rooday.com`. Then set
Plex's custom server access URL to `https://plex-proxy.<server>.rooday.com:443`.
