# engager backup

Duplicacy backs up the whole host (repository root `/`) to Backblaze B2 as
the storage named `backblaze`. duplicacy-util runs backup, prune and check
nightly from root's crontab and emails the result.

`/usr/local/bin/duplicacy-util` is the build from the
[ROODAY/duplicacy-util](https://github.com/ROODAY/duplicacy-util) fork
(`-version` prints `<dev>`); upstream's binary sends mail that Amazon SES
rejects.

These files are reference copies of what is on the host. Nothing installs
them: after changing one here, copy it to the host by hand (table below).
Converting this host to a systemd timer like `proxy-west/duplicacy` is a
tracked follow-up.

## Files

| Repo path | Host path |
|-----------|-----------|
| `engager/duplicacy/filters` | `/.duplicacy/filters` |
| `engager/duplicacy/engagerbackup.yaml` | `/home/rooday/.duplicacy-util/engagerbackup.yaml` |
| `engager/duplicacy/duplicacy-util.yaml.example` | `/home/rooday/.duplicacy-util/duplicacy-util.yaml` (fill in the SES SMTP credentials) |

Not in the repo, host-local only: `/.duplicacy/preferences` (B2 key and
storage password) and the Kuma push token in the crontab line.

## Schedule

Root's crontab (`sudo crontab -e`):

```
PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
0 5 * * * /usr/local/bin/duplicacy-util -sd /home/rooday/.duplicacy-util -f engagerbackup -a -q && curl -fsS -m 20 "https://status.rooday.com/api/push/<push-token>?status=up&msg=OK" >/dev/null
```

The push goes to the **engager backup** monitor in Uptime Kuma, only after a
successful run. The deploy timer (`engager/systemd`) runs at 04:30.

## Run it now

```bash
sudo /usr/local/bin/duplicacy-util -sd /home/rooday/.duplicacy-util -f engagerbackup -a
```
