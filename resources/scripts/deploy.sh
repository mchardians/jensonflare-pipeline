#!/usr/bin/env bash

set -Eeuo pipefail

RELEASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
set -a
. "$RELEASE_DIR/deploy.params"
set +a

: "${APP_DIR:?APP_DIR is not set}" "${IMAGE:?IMAGE is not set}" "${NEW_TAG:?NEW_TAG is not set}"
KEEP_TAGS="${KEEP_TAGS:-3}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-180}"
HEALTH_URL="${HEALTH_URL:-}"
HEALTH_RETRIES="${HEALTH_RETRIES:-20}"
HEALTH_INTERVAL="${HEALTH_INTERVAL:-5}"
GHCR_USER="${GHCR_USER:-}"
PULL_SERVICES="${PULL_SERVICES:-nginx php-fpm queue}"
IMAGE_SERVICES="${IMAGE_SERVICES:-nginx php-fpm php-cli}"
DEPENDENCY_SERVICES="${DEPENDENCY_SERVICES-mysql}"
MIGRATE_CMD="${MIGRATE_CMD-php artisan migrate --force}"
MIGRATE_SERVICE="${MIGRATE_SERVICE:-php-cli}"
BACKUP_SERVICE="${BACKUP_SERVICE:-}"
BACKUP_KEEP="${BACKUP_KEEP:-5}"
BACKUP_CMD="${BACKUP_CMD:-MYSQL_PWD=\"\$MYSQL_ROOT_PASSWORD\" mysqldump -u root --single-transaction --routines --triggers --no-tablespaces \"\$MYSQL_DATABASE\"}"
RECHECK_SECONDS="${RECHECK_SECONDS:-60}"
RECHECK_INTERVAL="${RECHECK_INTERVAL:-5}"
export IMAGE_SERVICES

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die()  { printf '[%s] FATAL: %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

retry() {
  local max_attempts="$1" attempt=1; shift
  until "$@"; do
    [ "$attempt" -ge "$max_attempts" ] && return 1
    warn "Attempt $attempt/$max_attempts failed, retrying in 5 seconds: $*"
    sleep 5; attempt=$((attempt + 1))
  done
}

GHCR_TOKEN=""
if [ -n "$GHCR_USER" ]; then
  IFS= read -r GHCR_TOKEN || true
  [ -n "$GHCR_TOKEN" ] || die "GHCR_USER is set but no token was received on stdin"
fi

command -v flock  >/dev/null || die "flock not found on the server"
command -v docker >/dev/null || die "docker not found on the server"

cd "$APP_DIR"
exec 9>.deploy.lock
flock -n 9 || die "Another deployment is already running in $APP_DIR"
[ -f .env ] || die ".env not found in $APP_DIR"

read_var() {
  [ -f "$1" ] || return 0
  { grep -E "^$2=" "$1" || true; } | tail -n1 | cut -d= -f2- | tr -d '\r"'
}

PREVIOUS_TAG="$(read_var .release.env IMAGE_TAG)"
[ -n "$PREVIOUS_TAG" ] || PREVIOUS_TAG="$(read_var .env IMAGE_TAG)"
[ "$PREVIOUS_TAG" != "latest" ] || PREVIOUS_TAG=""

HAD_RELEASE_FILE=0
if [ -f .release.env ]; then cp -p .release.env .release.env.prev; HAD_RELEASE_FILE=1; fi
CONTAINERS_REPLACED=0

write_release() {
  printf 'IMAGE_REGISTRY_PREFIX=%s\nIMAGE_TAG=%s\n' "$IMAGE" "$1" > .release.env.tmp
  mv .release.env.tmp .release.env
}

rollback() {
  if [ "$CONTAINERS_REPLACED" -eq 0 ]; then
    if [ "$HAD_RELEASE_FILE" -eq 1 ]; then cp -p .release.env.prev .release.env; else rm -f .release.env; fi
    warn "Old containers were not replaced; release pointer restored. (If the migration already ran, the database schema has changed.)"
    return 0
  fi
  if [ -z "$PREVIOUS_TAG" ]; then
    warn "No previous tag available, automatic rollback is not possible. Check manually."
    return 1
  fi
  warn "Rolling back to $PREVIOUS_TAG ..."
  write_release "$PREVIOUS_TAG"
  if compose up -d --remove-orphans --wait --wait-timeout "$WAIT_TIMEOUT"; then
    log "ROLLBACK SUCCEEDED: system is back on $PREVIOUS_TAG"
  else
    warn "ROLLBACK FAILED. Check: docker compose --env-file .env --env-file .release.env -f compose.base.yaml ps"
    return 1
  fi
}

fail() { warn "$1"; trap - ERR; rollback || true; exit 1; }
on_error() { local line="$1"; trap - ERR; warn "Unexpected error at line $line"; rollback || true; exit 1; }

install -m 0644 "$RELEASE_DIR/compose.base.yaml" compose.base.yaml
COMPOSE=(docker compose --env-file .env --env-file .release.env -f compose.base.yaml)
if [ -f "$RELEASE_DIR/docker-compose.override.yaml" ]; then
  install -m 0644 "$RELEASE_DIR/docker-compose.override.yaml" docker-compose.override.yaml
  COMPOSE+=(-f docker-compose.override.yaml)
else
  rm -f docker-compose.override.yaml
fi
compose() { "${COMPOSE[@]}" "$@" </dev/null; }

log "Deploying $IMAGE tag=$NEW_TAG (previous: ${PREVIOUS_TAG:-none})"
write_release "$NEW_TAG"
trap 'on_error $LINENO' ERR

compose config -q || fail "Invalid compose configuration (check variables in .env / .release.env)"

all_healthy() {
  local deadline=$((SECONDS + RECHECK_SECONDS)) ids states
  while :; do
    ids="$(compose ps -a -q)"
    if [ -n "$ids" ]; then
      states="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' $ids)"
      if ! printf '%s\n' "$states" | grep -qvE '^(healthy|running)$'; then return 0; fi
    fi
    [ "$SECONDS" -ge "$deadline" ] && return 1
    sleep "$RECHECK_INTERVAL"
  done
}

if [ -n "$GHCR_USER" ]; then
  printf '%s' "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USER" --password-stdin >/dev/null
  trap 'docker logout ghcr.io >/dev/null 2>&1 || true' EXIT
  GHCR_TOKEN=""
fi

log "Pulling application images"
retry 3 compose pull $PULL_SERVICES || fail "Failed to pull images from the registry"

if [ -n "$DEPENDENCY_SERVICES" ]; then
  log "Ensuring dependencies are healthy: $DEPENDENCY_SERVICES"
  compose up -d --wait --wait-timeout "$WAIT_TIMEOUT" $DEPENDENCY_SERVICES || fail "Dependencies are not healthy: $DEPENDENCY_SERVICES"
fi

backup_database() {
  mkdir -p backups
  local output timestamp
  timestamp="$(date +%Y%m%d-%H%M%S)"; output="backups/${NEW_TAG}-${timestamp}.sql.gz"
  log "Backing up database ($BACKUP_SERVICE) to $output"
  if compose exec -T "$BACKUP_SERVICE" sh -c "$BACKUP_CMD" | gzip > "$output.tmp" \
     && [ "$(gzip -dc "$output.tmp" | wc -c)" -gt 0 ]; then
    mv "$output.tmp" "$output"
  else
    rm -f "$output.tmp"; return 1
  fi
  ls -1t backups/*.sql.gz 2>/dev/null | tail -n +"$((BACKUP_KEEP + 1))" | while read -r old_backup; do rm -f "$old_backup"; done
}

if [ -n "$MIGRATE_CMD" ]; then
  if [ -n "$BACKUP_SERVICE" ]; then
    backup_database || fail "Database backup failed; migration aborted, old containers untouched"
  fi
  log "Running database migration"
  compose run --rm --no-deps -T "$MIGRATE_SERVICE" $MIGRATE_CMD \
    || fail "Migration failed; old containers untouched"
else
  log "Skipping migration (MIGRATE_CMD is empty)"
fi

log "Replacing containers (waiting for healthchecks, max ${WAIT_TIMEOUT}s)"
CONTAINERS_REPLACED=1
if ! compose up -d --remove-orphans --wait --wait-timeout "$WAIT_TIMEOUT"; then
  warn "up --wait failed; rechecking health for up to ${RECHECK_SECONDS}s before rolling back"
  all_healthy || fail "Containers are not healthy after replacement"
  log "Containers recovered; continuing without rollback"
fi

if [ -n "$HEALTH_URL" ]; then
  log "HTTP check: $HEALTH_URL"
  http_ok=0
  for _ in $(seq 1 "$HEALTH_RETRIES"); do
    if curl -fsS --max-time 5 -o /dev/null "$HEALTH_URL"; then http_ok=1; break; fi
    sleep "$HEALTH_INTERVAL"
  done
  [ "$http_ok" -eq 1 ] || fail "HTTP check failed after ${HEALTH_RETRIES} attempts ($HEALTH_URL)"
fi

trap - ERR
log "Healthy. Pruning old images (keeping the $KEEP_TAGS newest tags per image)"
bash "$RELEASE_DIR/prune-images.sh" "$IMAGE" "$KEEP_TAGS" "$NEW_TAG" "$PREVIOUS_TAG" \
  || warn "Image pruning failed (ignored)"
rm -f .release.env.prev

log "DEPLOY FINISHED: $NEW_TAG"