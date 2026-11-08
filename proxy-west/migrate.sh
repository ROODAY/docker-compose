#!/usr/bin/env bash
# One-time move from the host setup (nginx + certbot + librespeed.service +
# /opt/uptime-kuma) to this compose project. Safe to re-run.
#
#   sudo bash migrate.sh             migrate (rolls back by itself on failure)
#   sudo bash migrate.sh --rollback  go back to nginx/librespeed/old Kuma
#
# The old setup is disabled, not removed: nginx config, certbot certs,
# /opt/librespeed and the old Kuma volume all stay until you delete them.
set -euo pipefail

DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
OLD_KUMA="${OLD_KUMA:-/opt/uptime-kuma}"
HTPASSWD_SRC="${HTPASSWD_SRC:-/etc/nginx/.htpasswd-librespeed}"
OLD_UNITS=(nginx.service librespeed.service certbot.timer)

log() { printf '\n== %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || die "run with sudo"
cd "$DIR"
command -v docker >/dev/null || die "docker not found"

mapfile -t DOMAINS < <(grep -oP 'Host\(`\K[^`]+' traefik/dynamic.yml)
((${#DOMAINS[@]})) || die "no Host() rules found in traefik/dynamic.yml"

old_kuma() { docker compose -f "$OLD_KUMA/compose.yaml" "$@"; }

rollback() {
  trap - ERR
  log "rolling back to the host setup"
  docker compose down || true
  systemctl enable --now "${OLD_UNITS[@]}" || true
  if [[ -f "$OLD_KUMA/compose.yaml" ]]; then old_kuma up -d || true; fi
  log "rolled back; Kuma is on its pre-migration data"
}

if [[ "${1:-}" == "--rollback" ]]; then rollback; exit 0; fi
[[ -z "${1:-}" ]] || die "usage: $0 [--rollback]"

log "preflight"
[[ -f .env ]] || die "missing $DIR/.env (copy .env.example)"
# Read values without sourcing: .env is compose syntax, not shell.
envval() { grep -E "^$1=" .env | tail -n1 | cut -d= -f2- | sed -E "s/^(['\"])(.*)\1$/\2/"; }
for v in CF_DNS_API_TOKEN ACME_EMAIL LIBRESPEED_PASSWORD; do
  [[ -n "$(envval "$v")" ]] || die "$v is empty in .env"
done
verify="$(curl -fsS -H "Authorization: Bearer $(envval CF_DNS_API_TOKEN)" \
  https://api.cloudflare.com/client/v4/user/tokens/verify)" \
  || die "Cloudflare rejected CF_DNS_API_TOKEN"
grep -q '"status":"active"' <<<"$verify" || die "Cloudflare token is not active: $verify"
echo "cloudflare token: active"

# Orange cloud is fine for status pages, not for Plex (Cloudflare's free plan
# forbids proxying video and caps uploads at 100 MB) or librespeed.
myip="$(curl -fsS --max-time 5 http://169.254.169.254/metadata/v1/interfaces/public/0/ipv4/address || true)"
for d in "${DOMAINS[@]}"; do
  [[ "$d" == *plex* ]] || continue
  ip="$(getent ahostsv4 "$d" | awk 'NR==1{print $1}')"
  [[ -z "$myip" || "$ip" == "$myip" ]] \
    || echo "WARNING: $d resolves to ${ip:-nothing}, not $myip; set it to DNS only (grey) in Cloudflare"
done

config_out="$(docker compose config 2>&1)" || { echo "$config_out" >&2; die "docker compose config failed"; }
if grep -qi 'variable is not set' <<<"$config_out"; then
  grep -i 'variable is not set' <<<"$config_out" >&2; die "compose variables unset"
fi

mkdir -p data/traefik/letsencrypt data/uptime-kuma data/librespeed
[[ -f data/traefik/letsencrypt/acme.json ]] || install -m 600 /dev/null data/traefik/letsencrypt/acme.json
chmod 600 data/traefik/letsencrypt/acme.json

# Traefik's basicAuth accepts only MD5 (apr1), SHA1 and bcrypt hashes.
if [[ ! -s data/traefik/htpasswd-librespeed ]]; then
  [[ -s "$HTPASSWD_SRC" ]] || die "$HTPASSWD_SRC missing; create data/traefik/htpasswd-librespeed (htpasswd -B)"
  if grep -vqE '^[^:]+:(\$apr1\$|\$2[aby]\$|\{SHA\})' "$HTPASSWD_SRC"; then
    die "$HTPASSWD_SRC has a hash type Traefik cannot read; recreate it with: htpasswd -B -c data/traefik/htpasswd-librespeed <user>"
  fi
  install -m 600 "$HTPASSWD_SRC" data/traefik/htpasswd-librespeed
fi
echo "htpasswd: ok"

log "pulling images (old setup still serving)"
docker compose pull --quiet

# From here on the old setup goes down; any failure rolls back.
trap 'echo "step failed (line $LINENO)" >&2; rollback; exit 1' ERR

if [[ ! -s data/uptime-kuma/kuma.db ]]; then
  log "moving Uptime Kuma data out of the docker volume"
  [[ -f "$OLD_KUMA/compose.yaml" ]] || die "no kuma.db here and no $OLD_KUMA/compose.yaml to copy from"
  src="$(docker inspect uptime-kuma \
    --format '{{range .Mounts}}{{if eq .Destination "/app/data"}}{{.Source}}{{end}}{{end}}')"
  [[ -n "$src" && -f "$src/kuma.db" ]] || die "cannot find the old Kuma data volume"
  old_kuma stop
  cp -a "$src/." data/uptime-kuma/
  echo "copied $(du -sh data/uptime-kuma | cut -f1) from $src"
else
  log "data/uptime-kuma/kuma.db already present; not copying"
fi
if [[ -f "$OLD_KUMA/compose.yaml" ]]; then old_kuma down; fi

log "stopping the host setup"
systemctl disable --now "${OLD_UNITS[@]}"

log "starting the stack"
docker compose up -d --remove-orphans

log "waiting for certificates (curl must verify the cert, so the default cert fails)"
for d in "${DOMAINS[@]}"; do
  ok=0
  for _ in $(seq 1 60); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
      --resolve "$d:443:127.0.0.1" "https://$d/" || true)"
    if [[ "$code" != "000" ]]; then ok=1; break; fi
    sleep 5
  done
  ((ok)) || { echo "$d: no valid certificate after 5 minutes" >&2; false; }
  echo "$d: HTTP $code"
done

trap - ERR
log "done"
docker compose ps
cat <<EOF

Old setup is disabled but still on disk. Roll back with: sudo bash $0 --rollback
EOF
if docker compose config --services | grep -qx tailscale; then
  echo "Tailscale: open the login URL from: docker logs tailscale 2>&1 | grep -i login.tailscale"
fi
