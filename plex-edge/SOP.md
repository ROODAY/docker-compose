# SOP: Plex edge proxies

Runbooks for evaluating a region, bringing a proxy up, and taking one down.
For how the routing works, see [README.md](README.md). The examples use
`proxy-xyz` in DigitalOcean region `xyz1`. Replace both.

Tools on the admin PC: `doctl --context rooday`, `aws --profile route53` (IAM
user `route53-dns`, Route 53 only; never use the root credentials), `cf`
(Cloudflare, zone `rooday.com`) and `gh`.

| Thing | Value |
|---|---|
| Route 53 zone | `cdn.rooday.com`, `Z08004181SDY24KKH0R4X` |
| Steered name | `edge.cdn.rooday.com` (latency A records, TTL 60) |
| DO cloud firewall | `Firewall`, `d0d94dcc-9b92-4194-a311-bed93fbcbd58` (22/80/443 in) |
| DO SSH key | `Voidrunner`, `36940853` |
| Kuma | `status.rooday.com`; status page `homelab`, group "Proxies" |

## 1. Evaluate a region first (about 30 minutes, a few cents)

An edge only helps if its route to the home proxies beats the route straight
from the Plex servers. Some regions take odd routes: BLR1 reaches the US through
Europe, not across the Pacific. Measure before you commit.

The real proxies' firewalls (DO plus ufw) block iperf. Use throwaway droplets
instead: the candidate region, plus stand-ins in the home proxies' regions
(`sfo3` for proxy-west, `nyc3` for proxy-east).

```bash
cat > /tmp/test-init.yaml <<'EOF'
#cloud-config
packages: [iperf3, mtr-tiny, socat]
write_files:
  - path: /etc/sysctl.d/90-bbr.conf
    content: |
      net.core.default_qdisc=fq
      net.ipv4.tcp_congestion_control=bbr
      net.core.rmem_max=67108864
      net.core.wmem_max=67108864
      net.ipv4.tcp_rmem=4096 131072 67108864
      net.ipv4.tcp_wmem=4096 65536 67108864
runcmd: [sysctl --system, iperf3 -s -D]
EOF
for r in xyz1 sfo3 nyc3; do
  doctl --context rooday compute droplet create plex-test-$r --region $r \
    --size s-1vcpu-1gb --image ubuntu-24-04-x64 --ssh-keys 36940853 \
    --tag-names plex-test --user-data-file /tmp/test-init.yaml --wait
done
doctl --context rooday compute droplet list --tag-name plex-test --format Name,PublicIPv4
```

Wait for `ssh root@<ip> cloud-init status --wait`. Then, with `EDGE`, `SFO` and
`NYC` set to the droplet IPs:

```bash
# Latency. TCP connect time is one round trip; ICMP is blocked on the proxies.
ssh root@$EDGE 'for a in 137.184.32.90 104.248.10.1; do
  curl -sk -o /dev/null -w "%{time_connect}\n" https://$a/; done'

# Throughput in the streaming direction, one stream (a Plex video is one TCP stream).
# Direct, home server -> edge:
ssh intimidator "iperf3 -c $EDGE -t 10 -f m | tail -3"
ssh engager "docker run --rm networkstatic/iperf3 -c $EDGE -t 10 -f m | tail -3"

# Via a relay in the home region (models home proxy -> edge):
for ip in $SFO $NYC; do
  ssh root@$ip "nohup socat TCP-LISTEN:5202,fork,reuseaddr TCP:$EDGE:5201 >/dev/null 2>&1 &"
done
ssh intimidator "iperf3 -c $SFO -p 5202 -t 15 -O 3 -f m | tail -3"
ssh engager "docker run --rm networkstatic/iperf3 -c $NYC -p 5202 -t 15 -O 3 -f m | tail -3"

# Clean up
doctl --context rooday compute droplet delete --tag-name plex-test --force
for ip in $EDGE $SFO $NYC; do ssh-keygen -R $ip; done
```

**Go** if the relayed numbers clearly beat the direct ones and stay well above
your stream bitrates (4K remux needs 40-80 Mbit/s). Reference, BLR1 on
2026-11-16: engager 30 Mbit/s direct vs 316 relayed; intimidator 110 vs 131. To
compare two candidate regions, test both. Also run a speed test from where the
clients are, e.g. DigitalOcean's `speedtest-<region>.digitalocean.com`.

## 2. Bring a proxy up (about 30 minutes)

### Repo

1. `cp -r proxy-blr proxy-xyz`, then replace `proxy-blr` with `proxy-xyz` in every
   file and in the systemd unit file names.
2. In `docker-compose.yaml`: set `PROXY_NAME=proxy-xyz` and librespeed's `TZ`.
3. In `traefik/dynamic.yml`: set the librespeed host to `librespeed.proxy-xyz.rooday.com`.
4. In `systemd/proxy-xyz-update.timer`: pick a time no other proxy uses (blr 08:30,
   east 09:30, west 10:30 UTC).
5. Add `proxy-xyz` to `managerFilePatterns` in `renovate.json`.
6. Add a row to the proxy table in `README.md`, open a PR and merge it.

`traefik/plex.yml` does not change. It only lists each Plex server's home
proxy, so a pure edge needs no entry.

### Droplet (as root, one time)

```bash
cat > /tmp/proxy-init.yaml <<'EOF'
#cloud-config
package_update: true
package_upgrade: true
packages: [git, apache2-utils, iperf3, mtr-tiny]
swap: {filename: /swapfile, size: 2G}
runcmd: ["curl -fsSL https://get.docker.com | sh"]
EOF
doctl --context rooday compute droplet create proxy-xyz --region xyz1 \
  --size s-1vcpu-1gb --image ubuntu-26-04-x64 --ssh-keys 36940853 \
  --enable-monitoring --user-data-file /tmp/proxy-init.yaml --wait
doctl --context rooday compute firewall add-droplets d0d94dcc-9b92-4194-a311-bed93fbcbd58 --droplet-ids <id>
```

As root on the droplet (`IP` is the new droplet's address):

```bash
useradd -m -s /bin/bash rooday
install -d -m 700 -o rooday -g rooday /home/rooday/.ssh
install -m 600 -o rooday -g rooday /root/.ssh/authorized_keys /home/rooday/.ssh/
runuser -u rooday -- git clone https://github.com/ROODAY/docker-compose.git /home/rooday/docker-compose
cd /home/rooday/docker-compose
install -m 644 plex-edge/sysctl/90-plex-edge.conf /etc/sysctl.d/
install -m 644 plex-edge/sysctl/bbr.conf /etc/modules-load.d/
modprobe tcp_bbr && sysctl --system
cd proxy-xyz
runuser -u rooday -- mkdir -p data/traefik/letsencrypt data/librespeed
runuser -u rooday -- install -m 600 /dev/null data/traefik/letsencrypt/acme.json
runuser -u rooday -- install -m 600 /dev/null data/traefik/htpasswd-librespeed
```

Copy `.env` from another proxy without printing it (it has the same three keys):

```bash
ssh proxy-east 'cat ~/docker-compose/proxy-east/.env' \
  | ssh root@$IP 'install -o rooday -g rooday -m 600 /dev/stdin /home/rooday/docker-compose/proxy-xyz/.env'
```

Then, as root, start the stack and install the deploy timer:

```bash
cd /home/rooday/docker-compose/proxy-xyz && docker compose up -d && bash systemd/install.sh
```

### DNS

```bash
for n in proxy-xyz librespeed.proxy-xyz; do
  cf dns records create -z rooday.com --body "{\"type\":\"A\",\"name\":\"$n.rooday.com\",\"content\":\"$IP\",\"proxied\":false,\"ttl\":300}"
done
# Check that both Plex servers work through the new edge (wait a minute for certs):
for s in intimidator engager; do
  curl -s --resolve plex-proxy.$s.rooday.com:443:$IP https://plex-proxy.$s.rooday.com/identity | head -c 120; echo
done
```

Only once both return a `MediaContainer`, add the proxy to Route 53. Choose the
AWS region closest to the droplet (BLR1 uses ap-south-2, Hyderabad).

```bash
export AWS_PROFILE=route53
HC=$(aws route53 create-health-check --caller-reference "proxy-xyz-$(date +%s)" \
  --health-check-config "IPAddress=$IP,Port=443,Type=TCP,RequestInterval=30,FailureThreshold=3" \
  --query HealthCheck.Id --output text | tr -d '\r')
aws route53 change-tags-for-resource --resource-type healthcheck --resource-id $HC \
  --add-tags Key=Name,Value="proxy-xyz tcp/443"
aws route53 change-resource-record-sets --hosted-zone-id Z08004181SDY24KKH0R4X --change-batch \
  "{\"Changes\":[{\"Action\":\"UPSERT\",\"ResourceRecordSet\":{\"Name\":\"edge.cdn.rooday.com\",\"Type\":\"A\",\"SetIdentifier\":\"proxy-xyz\",\"Region\":\"<aws-region>\",\"TTL\":60,\"ResourceRecords\":[{\"Value\":\"$IP\"}],\"HealthCheckId\":\"$HC\"}}]}"
# Check routing for a client subnet in the target area:
aws route53 test-dns-answer --hosted-zone-id Z08004181SDY24KKH0R4X --record-name edge.cdn.rooday.com \
  --record-type A --resolver-ip 8.8.8.8 --edns0-client-subnet-ip <client-ip> --edns0-client-subnet-mask 24
```

Record the IP, droplet ID and health check ID in `proxy-xyz/README.md`.

### Uptime Kuma (status.rooday.com)

1. Add a group monitor `proxy-xyz`.
2. Inside it, add an HTTP monitor "Librespeed (proxy-xyz)" for
   `https://librespeed.proxy-xyz.rooday.com`. Accept `200-299` and `401` (basic
   auth), use a 60 s interval with 2 retries, and turn on the usual notification.
3. Inside it, add a push monitor "proxy-xyz deploy" with a 90000 s heartbeat
   interval, which is about 25 hours.
4. Add "Librespeed (proxy-xyz)" to the status page `homelab`, group "Proxies".

### Hand over to the rooday user

```bash
# As root:
passwd rooday && usermod -aG sudo rooday
# From a second terminal, check that ssh rooday@$IP 'sudo -v' works. Then, as rooday:
echo 'PermitRootLogin no' | sudo tee /etc/ssh/sshd_config.d/10-no-root.conf && sudo systemctl reload ssh
htpasswd -B -c ~/docker-compose/proxy-xyz/data/traefik/htpasswd-librespeed <user>
sudo docker restart traefik   # Traefik reads the htpasswd only at start
echo 'KUMA_PUSH_URL="https://status.rooday.com/api/push/<token>"' | sudo tee /etc/default/compose-updater >/dev/null
sudo chmod 600 /etc/default/compose-updater
bash ~/docker-compose/proxy-xyz/update-now.sh
```

Add a `Host proxy-xyz` block to `~/.ssh/config` on the PC.

## 3. Take a proxy down (about 10 minutes)

Keep the `proxy-xyz/` folder in the repo, so bringing the proxy back is section 2
without the repo steps.

1. **Route 53:** delete the `proxy-xyz` latency record first, so clients stop
   getting its IP.
   ```bash
   export AWS_PROFILE=route53
   aws route53 change-resource-record-sets --hosted-zone-id Z08004181SDY24KKH0R4X --change-batch \
     "{\"Changes\":[{\"Action\":\"DELETE\",\"ResourceRecordSet\":{\"Name\":\"edge.cdn.rooday.com\",\"Type\":\"A\",\"SetIdentifier\":\"proxy-xyz\",\"Region\":\"<aws-region>\",\"TTL\":60,\"ResourceRecords\":[{\"Value\":\"$IP\"}],\"HealthCheckId\":\"$HC\"}}]}"
   ```
   The DELETE must match the record exactly; copy it from `list-resource-record-sets`.
2. **Wait 5-10 minutes.** The TTL is 60 s, but some resolvers and Plex clients cache longer.
3. **Droplet:** `doctl --context rooday compute droplet delete proxy-xyz --force`
4. **Health check:** `aws route53 delete-health-check --health-check-id $HC`
5. **Cloudflare:** delete the `proxy-xyz` and `librespeed.proxy-xyz` A records
   (`cf dns records delete <id> -z rooday.com --force`).
6. **Uptime Kuma:** take "Librespeed (proxy-xyz)" off the status page, then
   delete the `proxy-xyz` group and its two monitors.
7. **PC:** `ssh-keygen -R $IP`, and comment out the `Host proxy-xyz` block.
8. **Repo (optional):** to stop Renovate PRs while the proxy is down, remove it
   from `managerFilePatterns` in `renovate.json`. Note in `proxy-xyz/README.md`
   that it is retired.
