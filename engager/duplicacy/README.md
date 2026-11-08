# engager backup

Duplicacy backs up the whole host (repository root `/`) to Backblaze B2 as
the storage named `backblaze`. `engager-backup.timer` runs duplicacy-util
(backup, prune, check) daily at 02:00 host time plus up to 30 minutes of
jitter, clear of the deploy timer at 04:30. duplicacy-util emails the result.

`/usr/local/bin/duplicacy-util` is the build from the
[ROODAY/duplicacy-util](https://github.com/ROODAY/duplicacy-util) fork
(`-version` prints `<dev>`); upstream's binary sends mail that Amazon SES
rejects.

## Files

| Repo path | Host path | Installed by |
|-----------|-----------|--------------|
| `engager/duplicacy/filters` | `/.duplicacy/filters` | `install.sh` |
| `engager/duplicacy/engager.yaml` | `/etc/duplicacy-util/engager.yaml` | `install.sh` |
| `engager/duplicacy/duplicacy-util.yaml.example` | `/etc/duplicacy-util/duplicacy-util.yaml` | you (SES SMTP credentials) |

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
sudo bash engager/duplicacy/install.sh
```

Re-run `install.sh` after changing `filters` or `engager.yaml` here. The push
goes to the **engager backup** monitor in Uptime Kuma, only after a successful run.

## Run it now

```bash
sudo systemctl start engager-backup.service     # blocks until the run finishes
sudo journalctl -u engager-backup.service -n 20 --no-pager
systemctl list-timers engager-backup.timer
```
