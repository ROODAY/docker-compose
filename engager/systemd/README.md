# engager deploy

Git is the source of truth. Renovate opens image-update PRs, and this systemd
timer deploys whatever lands on `main` to engager.

## What the timer does

Daily at 04:30 local time (up to 30 minutes of jitter):

1. Fast-forwards `/home/rooday/docker-compose` to `origin/main` over anonymous
   HTTPS. Fetch/merge failures are warnings; the current checkout is deployed.
2. Re-syncs the installed units and script from the repo copy when they changed
   (the new version takes effect on the next run).
3. Validates `docker compose config` and fails if any `${VAR}` is unset (Compose
   itself only warns). Values come from `engager/.env`.
4. `docker compose pull --ignore-pull-failures`, then one
   `docker compose up -d --remove-orphans` for the whole project, so
   `depends_on`/`restart: true` ordering is honoured. There is deliberately no
   `--wait`: kometa and recyclarr exit by design, so `--wait` would fail every
   run. If that `up` fails, Compose has usually left everything after the
   failing container in Created, so the script retries `docker compose up -d
   <service>` once per service (dependencies included, no `--no-deps`). Healthy
   services come back, and the run still fails, naming the services that
   would not start, including those whose dependency is broken. Pruning is
   skipped on a failed run.
5. Prunes dangling images older than 14 days. The previous image stays
   available for rollback.

A dirty `engager/` checkout — tracked, staged, or untracked files — is refused
(`ERROR: dirty engager worktree`), because deploying uncommitted state defeats
git-as-source-of-truth. Dirt elsewhere in the repo (for example `intimidator/`)
does not block an engager deploy. For a deliberate manual run, set
`ALLOW_DIRTY=1`; the timer never sets it.

## When it runs

Daily at **04:30 host time**, plus up to 30 minutes of jitter, with
`Persistent=true` so a missed run catches up after downtime. Check the next
fire with `systemctl list-timers engager-update.timer`.

Engager's host clock is currently EST, so 04:30 is 01:30 on the US west coast —
the usual low-use window for a media stack (after evening streams, before
morning use). To change it, edit `OnCalendar=` in `engager-update.timer` and
re-run `sudo bash ./engager/systemd/install.sh`.

A 6-hourly schedule
(`OnCalendar=*-*-* 00,06,12,18:30:00`) is reasonable if you want new versions
to land sooner; hourly is usually overkill for a media stack.

## Requirements

- root (the service runs as root)
- Docker Compose v2.20+ (needed for `include:`; also covers the
  `depends_on.restart` field, which needs v2.17+)
- `git`, `flock`, `runuser`, `bash`
- an `.env` at `/home/rooday/docker-compose/engager/.env`
- the checkout at `/home/rooday/docker-compose`, owned by `rooday`

## Install

```bash
sudo bash ./engager/systemd/install.sh
```

`bash` is used explicitly because a Windows checkout with `core.filemode=false`
does not record the executable bit; the script does not rely on it.

It copies `update-containers.sh` to `/usr/local/lib/engager-updater/`, installs
both units to `/etc/systemd/system/`, runs `systemctl daemon-reload`, and
enables + starts `engager-update.timer`. Running it again is a no-op when
nothing changed.

## Check for a newer installed version

```bash
bash ./engager/systemd/install.sh --check
```

Prints `up to date (v<hash>)`, or `update available: ...` and exits 1. The
version is a hash of the installed artefacts, so no hand-maintained version
number can go stale. The daily service also runs `install.sh --if-changed`
itself, so a newer unit version in the repo is applied automatically.

## Run it now

```bash
bash ./engager/update-now.sh
```

This starts `engager-update.service`, waits for the oneshot to finish, and
prints the last 20 journal lines. The manual equivalent:

```bash
sudo systemctl start engager-update.service
journalctl -u engager-update -f
```

## Updates

Image updates come from Renovate. See [Updates](../../README.md#updates) in
the root README for what automerges and how to push an urgent update.

## Failure email

`engager-update.service` has `OnFailure=engager-update-notify.service`, which runs
`notify-failure.sh`: it mails the failed run's log (last 80 lines), the number
of running containers, and every container that is not running. Mail goes through
the local postfix, which relays via Amazon SES.

The addresses are host-local and never committed:

```bash
sudo tee /etc/default/compose-updater >/dev/null <<'EOF'
NOTIFY_FROM="Engager Docker Updater <engager@mail.rooday.com>"
NOTIFY_TO="Name <you@example.com>"
EOF
```

Without that file the hook logs a line and sends nothing. To send a test email
built from the last run's log: `sudo systemctl start engager-update-notify.service`.

## Rollback

Revert the offending commit on `main`, then:

```bash
sudo systemctl start engager-update.service
```

A checkout-only rollback does not stick: the next run fast-forwards back to
`main`. The previous image is still present for up to 14 days.

## Uninstall

```bash
sudo bash ./engager/systemd/install.sh --uninstall
```

## Files

| Repo path | Installed path |
|-----------|----------------|
| `engager/systemd/update-containers.sh` | `/usr/local/lib/engager-updater/update-containers.sh` |
| `engager/systemd/engager-update.service` | `/etc/systemd/system/engager-update.service` |
| `engager/systemd/engager-update.timer` | `/etc/systemd/system/engager-update.timer` |
| `engager/systemd/notify-failure.sh` | `/usr/local/lib/engager-updater/notify-failure.sh` |
| `engager/systemd/engager-update-notify.service` | `/etc/systemd/system/engager-update-notify.service` |
