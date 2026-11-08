# intimidator backup

Duplicacy backs up the whole host (repository root `/`) to Backblaze B2 as
the storage named `backblaze`. `intimidator-backup.timer` runs duplicacy-util
(backup, prune, check) daily at 02:00 host time plus up to 30 minutes of
jitter, clear of the deploy timer at 05:00. duplicacy-util emails the result.

`/usr/local/bin/duplicacy-util` is the build from the
[ROODAY/duplicacy-util](https://github.com/ROODAY/duplicacy-util) fork
(`-version` prints `<dev>`); upstream's binary sends mail that Amazon SES
rejects.

The intimidator filters also back up `/mnt/tank` (except `mnt/tank/backups`) and
`/mnt/docker` (except `mnt/docker/docker-root`). intimidator is the Proxmox
host itself (hostname still `pve`).

## Files

| Repo path | Host path | Installed by |
|-----------|-----------|--------------|
| `intimidator/duplicacy/filters` | `/.duplicacy/filters` | `install.sh` |
| `intimidator/duplicacy/intimidator.yaml` | `/etc/duplicacy-util/intimidator.yaml` | `install.sh` |
| `intimidator/duplicacy/duplicacy-util.yaml.example` | `/etc/duplicacy-util/duplicacy-util.yaml` | you (SES SMTP credentials) |

Host-local, never committed: `/.duplicacy/preferences` (B2 key and storage
password), `/etc/duplicacy-util/duplicacy-util.yaml`, and
`BACKUP_PUSH_URL` in `/etc/default/compose-updater`.

## Install

Needs Duplicacy and the duplicacy-util fork in `/usr/local/bin`, an
initialised `/.duplicacy`, and `/etc/duplicacy-util/duplicacy-util.yaml`.
Put the Kuma push URL in `/etc/default/compose-updater`:

```
BACKUP_PUSH_URL="https://status.rooday.com/api/push/<push-token>"
```

```bash
sudo bash intimidator/duplicacy/install.sh
```

Re-run `install.sh` after changing `filters` or `intimidator.yaml` here. The push
goes to the **intimidator backup** monitor in Uptime Kuma, only after a successful run.

## Run it now

```bash
sudo systemctl start intimidator-backup.service     # blocks until the run finishes
sudo journalctl -u intimidator-backup.service -n 20 --no-pager
systemctl list-timers intimidator-backup.timer
```
