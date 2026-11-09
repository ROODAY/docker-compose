# docker-compose

My docker compose files, organized by server

## Updates

Git is the source of truth. Each host runs a daily systemd timer that
fast-forwards to `main` and runs `docker compose up -d`. Host details live in
`<host>/systemd/README.md`.

[Renovate](https://docs.renovatebot.com/) proposes image updates. It runs as
the Mend GitHub app, configured in `renovate.json`. The Dependency Dashboard
issue lists everything pending and has a checkbox that triggers a run.

**Automerge.** This applies to engager and intimidator only, through opt-in
lists in `renovate.json`. Once a release is 3 days old, Renovate commits it
straight to `main` with no PR, and the next timer run deploys it:

| Tier | Updates merged | Examples |
|---|---|---|
| Low-risk apps | minor, patch, digest | LinuxServer *arr apps, plex, kometa, recyclarr |
| Stateful apps | patch only | ghost, synapse, immich, gluetun, qbittorrent, mysql |
| Postgres | minor within 16 | postgres (its minors are bug-fix releases) |

Everything else arrives as a PR, including any newly added image. These are
never automerged: traefik, tailscale, the GPU images (faster-whisper, ollama),
the immich postgres image, and anything in `proxy-*`. Major versions always
arrive as PRs, and Renovate is disabled outright for database majors.

Images whose registry reports no publish date skip the 3-day wait.

**Urgent update.** There are no security PRs for container images, so this
step is manual:

1. Get the new version onto `main`: merge its PR, tick it in the Dependency
   Dashboard if it is still waiting out the 3 days, or edit the tag yourself.
2. Deploy it now instead of waiting for the timer: `bash ./<host>/update-now.sh`.

**Rollback.** `git revert` the update commit and push, then run
`update-now.sh`. The previous image stays on the host for 14 days. Some apps
migrate their database on start (ghost, synapse, grampsweb, tandoor), and for
those you may also need to restore their data from the nightly Duplicacy
backup.
