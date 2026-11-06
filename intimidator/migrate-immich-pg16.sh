#!/usr/bin/env bash
#
# Migrate Immich's PostgreSQL 14 cluster to PostgreSQL 16 (dump/restore).
#
# Run from anywhere; the script cd's to its own directory:
#   bash migrate-immich-pg16.sh
#
# Roll back to the PG14 data dir (while it still exists):
#   bash migrate-immich-pg16.sh --rollback
#
# Non-interactive:
#   bash migrate-immich-pg16.sh --yes
#
# The dump is the logical backup; the moved PG14 data dir is the instant
# rollback. Keep both until the PG16 instance has been verified for a few days.
# If the script fails after moving the data dir, run --rollback.

set -euo pipefail

COMPOSE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$COMPOSE_DIR"

COMPOSE_FILE="immich.yaml"
DB_SERVICE="database"
DB_CONTAINER="immich_postgres"
APP_SERVICES=(immich-server immich-machine-learning)
# Digest from Immich's PG16 image; same VectorChord/pgvecto.rs versions as the
# current PG14 image (vchord 0.4.3, pgvectors 0.2.0).
NEW_IMAGE="ghcr.io/immich-app/postgres:16-vectorchord0.4.3-pgvectors0.2.0@sha256:1a078b237c1d9b420b0ee59147386b4aa60d3a07a8e6a402fc84a57e41b043a4"
STATE_FILE="${HOME}/immich-pg16-migration.state"
BACKUP_DIR="${HOME}/immich-backups"
DATE="$(date +%Y%m%d-%H%M%S)"
DUMP="${BACKUP_DIR}/immich-pg14-${DATE}.dump"
REQUIRED_EXTENSIONS=(vchord vector vectors pg_trgm unaccent uuid-ossp cube earthdistance)

RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; NC=$'\e[0m'
say()  { printf '%s\n' "$*"; }
ok()   { printf '%s%s%s\n' "$GREEN" "$*" "$NC"; }
warn() { printf '%sWARNING: %s%s\n' "$YELLOW" "$*" "$NC"; }
die()  { printf '%sERROR: %s%s\n' "$RED" "$*" "$NC" >&2; exit 1; }

MIGRATION_STARTED=0
trap 'if [ "${MIGRATION_STARTED:-0}" = "1" ]; then printf "\n%s\n" "Migration failed. Roll back with: bash $0 --rollback"; fi' ERR

env_value() {
  local key="$1"
  grep -E "^${key}=" .env | tail -1 | cut -d= -f2-
}

DATA_DIR="$(env_value DB_DATA_LOCATION)"
DB_NAME="$(env_value DB_DATABASE_NAME)"
[ -n "$DATA_DIR" ] || die "DB_DATA_LOCATION is missing from .env"
[ -n "$DB_NAME" ] || die "DB_DATABASE_NAME is missing from .env"
DATA_PARENT="$(dirname "$DATA_DIR")"
DATA_BASE="$(basename "$DATA_DIR")"
OLD_DATA_DIR=""
OLD_IMAGE=""

current_image() {
  grep -E "^[[:space:]]+image: ghcr.io/immich-app/postgres:" "$COMPOSE_FILE" \
    | head -1 | sed -E 's/^[[:space:]]+image:[[:space:]]+//'
}

set_image() {
  sed -i -E "s|^([[:space:]]+image:[[:space:]]+)ghcr.io/immich-app/postgres:.*|\1$1|" "$COMPOSE_FILE"
  grep -qF "$1" "$COMPOSE_FILE" || die "failed to write the image into $COMPOSE_FILE"
}

db_version() {
  docker exec -i "$DB_CONTAINER" sh -c 'exec psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "SHOW server_version;"' 2>/dev/null | tr -d '[:space:]'
}

wait_for_db() {
  local i
  for i in $(seq 1 60); do
    if docker exec "$DB_CONTAINER" sh -c 'exec pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB"' >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_for_app() {
  local i
  for i in $(seq 1 120); do
    if curl -fsS -o /dev/null http://localhost:2283/api/server/version 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  return 1
}

dump_db() {
  mkdir -p "$BACKUP_DIR"
  say "Dumping ${DB_NAME} from PostgreSQL 14 ..."
  docker exec -i "$DB_CONTAINER" sh -c 'exec pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc' > "$DUMP"
  [ -s "$DUMP" ] || die "dump is empty"
  docker exec -i "$DB_CONTAINER" sh -c 'exec pg_restore -l' < "$DUMP" >/dev/null \
    || die "pg_restore cannot read the dump"
  ok "Dump: $DUMP ($(du -h "$DUMP" | cut -f1))"
}

move_data_dir() {
  OLD_DATA_DIR="${DATA_PARENT}/${DATA_BASE}.14-old-${DATE}"
  [ -e "$OLD_DATA_DIR" ] && die "target already exists: $OLD_DATA_DIR"
  say "Moving the PG14 data dir aside ..."
  mv "$DATA_DIR" "$OLD_DATA_DIR"
  mkdir -p "$DATA_DIR"
  chmod 700 "$DATA_DIR"
  ok "PG14 data dir kept at $OLD_DATA_DIR"
}

write_state() {
  cat > "$STATE_FILE" <<EOF
OLD_IMAGE=${OLD_IMAGE}
NEW_IMAGE=${NEW_IMAGE}
DATA_DIR=${DATA_DIR}
OLD_DATA_DIR=${OLD_DATA_DIR}
EOF
}

check_extensions() {
  local available ext
  available="$(docker exec -i "$DB_CONTAINER" sh -c 'exec psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "SELECT name FROM pg_available_extensions;"')"
  for ext in "${REQUIRED_EXTENSIONS[@]}"; do
    printf '%s\n' "$available" | grep -qx "$ext" || die "PG16 image is missing extension: $ext"
  done
}

restore_db() {
  say "Restoring the dump into PostgreSQL 16 ..."
  docker exec -i "$DB_CONTAINER" sh -c 'exec pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner --no-privileges --exit-on-error' < "$DUMP"
}

rollback() {
  [ -f "$STATE_FILE" ] || die "no state file at $STATE_FILE"
  # shellcheck disable=SC1090
  . "$STATE_FILE"
  [ -n "${OLD_DATA_DIR:-}" ] && [ -d "$OLD_DATA_DIR" ] || die "PG14 data dir not found: ${OLD_DATA_DIR:-unset}"
  say "Rolling back to ${OLD_IMAGE}"
  docker compose stop "${APP_SERVICES[@]}" "$DB_SERVICE" >/dev/null 2>&1 || true
  local failed="${DATA_PARENT}/${DATA_BASE}.16-failed-${DATE}"
  if [ -e "$DATA_DIR" ]; then
    [ -e "$failed" ] && die "target already exists: $failed"
    mv "$DATA_DIR" "$failed"
    say "Current data dir kept at $failed"
  fi
  mv "$OLD_DATA_DIR" "$DATA_DIR"
  set_image "$OLD_IMAGE"
  docker compose up -d "$DB_SERVICE"
  wait_for_db || die "PostgreSQL 14 did not start"
  docker compose up -d "${APP_SERVICES[@]}"
  wait_for_app || warn "Immich has not answered yet; check docker compose logs"
  ok "Rolled back. Commit the reverted image line if this is final."
}

main() {
  [ -f "$COMPOSE_FILE" ] || die "$PWD/$COMPOSE_FILE not found"
  [ -f .env ] || die ".env not found in $PWD"
  docker compose config -q || die "docker compose config failed"

  OLD_IMAGE="$(current_image)"
  [ -n "$OLD_IMAGE" ] || die "could not find the immich postgres image line"
  case "$OLD_IMAGE" in
    *:14-*) ;;
    *) die "expected a PostgreSQL 14 image, found: $OLD_IMAGE" ;;
  esac

  local running free
  running="$(db_version)" || die "$DB_CONTAINER is not running"
  case "$running" in
    14.*) ;;
    *) die "expected PostgreSQL 14, got '$running'" ;;
  esac
  free="$(df -Pk "$DATA_PARENT" | awk 'NR==2 {print $4}')"
  [ "${free:-0}" -gt 2097152 ] || die "need at least 2 GB free in $DATA_PARENT"

  say "Immich PostgreSQL migration"
  say "  current: $OLD_IMAGE"
  say "  target:  $NEW_IMAGE"
  say "  data:    $DATA_DIR"
  say "  dump:    $DUMP"
  say "Expect a few minutes of Immich downtime."
  if [ "${ASSUME_YES:-0}" != "1" ]; then
    printf "Type 'yes' to continue: "
    read -r answer
    [ "$answer" = "yes" ] || die "aborted"
  fi

  say "Pulling the PG16 image (before any downtime) ..."
  docker pull "$NEW_IMAGE" >/dev/null

  dump_db

  say "Stopping Immich ..."
  docker compose stop "${APP_SERVICES[@]}" >/dev/null
  say "Stopping PostgreSQL 14 ..."
  docker compose stop "$DB_SERVICE" >/dev/null

  move_data_dir
  MIGRATION_STARTED=1
  write_state
  set_image "$NEW_IMAGE"

  say "Starting PostgreSQL 16 on an empty data dir ..."
  docker compose up -d "$DB_SERVICE"
  wait_for_db || die "PostgreSQL 16 did not start"
  check_extensions
  restore_db

  say "Starting Immich ..."
  docker compose up -d "${APP_SERVICES[@]}"
  wait_for_app || warn "Immich has not answered yet; check docker compose logs"

  ok "Migration complete: PostgreSQL $(db_version)"
  say "  assets: $(docker exec -i "$DB_CONTAINER" sh -c 'exec psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "SELECT count(*) FROM asset;"')"
  say ""
  say "Next:"
  say "  1. Open Immich and check a few photos/thumbnails."
  say "  2. Commit the image change:"
  say "       git -C $(dirname "$COMPOSE_DIR") add intimidator/$COMPOSE_FILE"
  say "       git -C $(dirname "$COMPOSE_DIR") commit -m 'Upgrade immich postgres to PG16'"
  say "       git -C $(dirname "$COMPOSE_DIR") push"
  say "  3. Keep these for a few days:"
  say "       $OLD_DATA_DIR"
  say "       $DUMP"
  say "  4. Rollback if needed: bash $0 --rollback"
}

ASSUME_YES=0
case "${1:-}" in
  --yes|-y) ASSUME_YES=1; main ;;
  --rollback) rollback ;;
  "") main ;;
  *) die "unknown option: $1 (use --yes or --rollback)" ;;
esac
