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
| `engager/duplicacy/duplicacy-util.yaml.example` | `/etc/duplicacy-util/duplicacy-util.yaml` | you (SES SMTP credentials); `install.sh` copies it once from `/home/rooday/.duplicacy-util` |

Host-local, never committed: `/.duplicacy/preferences` (B2 key and storage
password), `/etc/duplicacy-util/duplicacy-util.yaml`, and
`BACKUP_PUSH_URL` in `/etc/default/compose-updater`.

## Install / move off cron

`install.sh` refuses to run while root's crontab still calls
duplicacy-util, so the backup can never run twice.

```bash
sudo crontab -l | grep duplicacy-util      # note the push token in the URL
sudo nano /etc/default/compose-updater     # add the line below
#   BACKUP_PUSH_URL="https://status.rooday.com/api/push/<push-token>"
sudo crontab -e                            # delete the duplicacy-util line
cd ~/docker-compose && git pull
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
