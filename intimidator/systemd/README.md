# intimidator deploy

Git is the source of truth. Renovate opens image-update PRs, and this systemd
timer deploys whatever lands on `main` to intimidator. It replaces
`intimidator/pull_and_redeploy.sh`.

## What the timer does

Daily at 05:00 local time (up to 30 minutes of jitter):

1. Fast-forwards `/home/rooday/docker-compose` to `origin/main` over anonymous
   HTTPS. Fetch/merge failures are warnings; the current checkout is deployed.
2. Re-syncs the installed units and script from the repo copy when they changed
   (the new version takes effect on the next run).
3. Validates `docker compose config` and fails if any `${VAR}` is unset (Compose
   itself only warns). Values come from `intimidator/.env`.
4. `docker compose pull --ignore-pull-failures`, then one
   `docker compose up -d --remove-orphans` for the whole project, so
   `depends_on`/`restart: true` ordering is honoured. There is deliberately no
   `--wait`: kometa and recyclarr exit by design, so `--wait` would fail every
   run.
5. Prunes dangling images older than 14 days. The previous image stays
   available for rollback.

A dirty `intimidator/` checkout — tracked, staged, or untracked files — is
refused (`ERROR: dirty intimidator worktree`), because deploying uncommitted
state defeats git-as-source-of-truth. Dirt elsewhere in the repo (for example
`engager/`) does not block an intimidator deploy. For a deliberate manual run,
set `ALLOW_DIRTY=1`; the timer never sets it.

## When it runs

Daily at **05:00 host time**, plus up to 30 minutes of jitter, with
`Persistent=true` so a missed run catches up after downtime. Check the next
fire with `systemctl list-timers intimidator-update.timer`.

Engager runs its own timer at 04:30 on a different host, so the two never
collide. To change the time, edit `OnCalendar=` in
`intimidator-update.timer` and re-run `sudo bash ./intimidator/systemd/install.sh`.

## Requirements

- root (the service runs as root)
- Docker Compose v2.20+ (needed for `include:`; also covers the
  `depends_on.restart` field, which needs v2.17+)
- `git`, `flock`, `runuser`, `bash`
- an `.env` at `/home/rooday/docker-compose/intimidator/.env`
- the checkout at `/home/rooday/docker-compose`, owned by `rooday`

## Install

```bash
sudo bash ./intimidator/systemd/install.sh
```

`bash` is used explicitly because the Windows checkout has
`core.filemode=false` and does not record the executable bit; the script does
not rely on it.

It copies `update-containers.sh` to `/usr/local/lib/intimidator-updater/`,
installs both units to `/etc/systemd/system/`, runs `systemctl daemon-reload`,
and enables + starts `intimidator-update.timer`. Running it again is a no-op
when nothing changed.

## Check for a newer installed version

```bash
bash ./intimidator/systemd/install.sh --check
```

Prints `up to date (v<hash>)`, or `update available: ...` and exits 1. The
version is a hash of the installed artefacts, so no hand-maintained version
number can go stale. The daily service also runs `install.sh --if-changed`
itself, so a newer unit version in the repo is applied automatically.

## Run it now

```bash
bash ./intimidator/update-now.sh
```

This starts `intimidator-update.service`, waits for the oneshot to finish, and
prints the last 20 journal lines. The manual equivalent:

```bash
sudo systemctl start intimidator-update.service
journalctl -u intimidator-update -f
```

## Rollout order

1. Merge `renovate.json` and let Renovate open the first intimidator PRs.
2. Remove the `docksmith` service and its labels from the intimidator compose
   files. Until that commit is on `main`, docksmith keeps running alongside the
   timer and its container is left alone. After it lands, the next deploy's
   `docker compose up -d --remove-orphans` deletes the container.
3. `sudo bash ./intimidator/systemd/install.sh`
4. `sudo systemctl start intimidator-update.service` and watch the journal.

## Rollback

Revert the offending commit on `main`, then:

```bash
sudo systemctl start intimidator-update.service
```

A checkout-only rollback does not stick: the next run fast-forwards back to
`main`. The previous image is still present for up to 14 days.

## Uninstall

```bash
sudo bash ./intimidator/systemd/install.sh --uninstall
```

## Files

| Repo path | Installed path |
|-----------|----------------|
| `intimidator/systemd/update-containers.sh` | `/usr/local/lib/intimidator-updater/update-containers.sh` |
| `intimidator/systemd/intimidator-update.service` | `/etc/systemd/system/intimidator-update.service` |
| `intimidator/systemd/intimidator-update.timer` | `/etc/systemd/system/intimidator-update.timer` |
