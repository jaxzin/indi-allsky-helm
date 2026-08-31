#!/usr/bin/env bash
# Disposable runtime proof for the chart's MariaDB file-secret and datadir
# contracts.
#
# The scheduled backup used to be proven here, against the CronJob's inline
# command. That command is gone: the dump now runs through the shipped,
# lock-wrapped scripts, and db-maintenance-behavior.sh proves it there — against
# the same disposable MariaDB, plus the serialization and collision properties
# an inline script could never have.
#
# All credentials are generated test fixtures and are never printed; output is
# limited to non-secret metadata and pass/fail summaries.
set -Eeuo pipefail

SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIRECTORY="$(cd -- "${SCRIPT_DIRECTORY}/.." && pwd)"
BASE_VALUES="${SCRIPT_DIRECTORY}/a5-values.yaml"
RELEASE_NAME="behavior"

BENCH_ID="a5-${$}"
NETWORK_NAME="${BENCH_ID}-network"
DATABASE_CONTAINER="${BENCH_ID}-mariadb"
DATABASE_VOLUME="${BENCH_ID}-database"
APP_SECRET_VOLUME="${BENCH_ID}-app-secret"
ROOT_SECRET_VOLUME="${BENCH_ID}-root-secret"
SCRATCH_DIRECTORY="$(mktemp -d)"

DATABASE_NAME="-allsky"
DATABASE_USER="indi_allsky"
EXPECTED_SECRET_MODE="440:0:999"
STARTUP_ATTEMPTS="120"
STARTUP_DELAY_SECONDS="1"

# Runtime-derived dummy values avoid embedding a credential-like literal in
# tracked source while remaining deterministic within this disposable run.
APP_PASSWORD="$(printf 'A5 application bench %s' "$BENCH_ID" | sha256sum | cut -c1-24)"
ROOT_PASSWORD="$(printf 'A5 root bench %s' "$BENCH_ID" | sha256sum | cut -c1-24)"

cleanup() {
    docker rm -f "$DATABASE_CONTAINER" >/dev/null 2>&1 || true
    docker network rm "$NETWORK_NAME" >/dev/null 2>&1 || true
    docker volume rm \
        "$DATABASE_VOLUME" "$APP_SECRET_VOLUME" "$ROOT_SECRET_VOLUME" \
        >/dev/null 2>&1 || true
    rm -rf -- "$SCRATCH_DIRECTORY"
}
trap cleanup EXIT INT TERM HUP

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

wait_for_database() {
    local attempt
    for ((attempt = 1; attempt <= STARTUP_ATTEMPTS; attempt++)); do
        if docker exec "$DATABASE_CONTAINER" \
            healthcheck.sh --connect --innodb_initialized >/dev/null 2>&1; then
            return 0
        fi
        sleep "$STARTUP_DELAY_SECONDS"
    done
    printf 'MariaDB did not become healthy after %s attempts\n' "$STARTUP_ATTEMPTS" >&2
    docker logs "$DATABASE_CONTAINER" 2>&1 \
        | sed -E 's/((secret|password|passwd|token|api_?key|credential)[^=:]*[=:]).*/\1***MASKED***/Ig' \
        | tail -n 40 >&2
    return 1
}

start_database() {
    docker run --detach \
        --name "$DATABASE_CONTAINER" \
        --network "$NETWORK_NAME" \
        --user 999:999 \
        --env "MARIADB_DATABASE=${DATABASE_NAME}" \
        --env "MARIADB_USER=${DATABASE_USER}" \
        --env MARIADB_PASSWORD_FILE=/run/secrets/app/MARIADB_PASSWORD \
        --env MARIADB_ROOT_PASSWORD_FILE=/run/secrets/root/MARIADB_ROOT_PASSWORD \
        --env MARIADB_ROOT_HOST=localhost \
        --volume "${DATABASE_VOLUME}:/var/lib/mysql" \
        --volume "${APP_SECRET_VOLUME}:/run/secrets/app:ro" \
        --volume "${ROOT_SECRET_VOLUME}:/run/secrets/root:ro" \
        "$DATABASE_IMAGE" \
        --character-set-server=utf8mb4 \
        --collation-server=utf8mb4_unicode_ci >/dev/null
    wait_for_database
}

docker network create "$NETWORK_NAME" >/dev/null
docker volume create "$DATABASE_VOLUME" >/dev/null
docker volume create "$APP_SECRET_VOLUME" >/dev/null
docker volume create "$ROOT_SECRET_VOLUME" >/dev/null

DATABASE_IMAGE="$(
    helm template "$RELEASE_NAME" "$CHART_DIRECTORY" \
        --values "$BASE_VALUES" \
        --show-only templates/mariadb-statefulset.yaml \
        | yq eval -r '.spec.template.spec.containers[0].image' -
)"
test -n "$DATABASE_IMAGE" || fail "rendered MariaDB image is empty"

# Reproduce Kubernetes Secret projection: root-owned files, group-readable by
# fsGroup 999, mode 0440. Initialize writable volumes for the two runtime UIDs.
docker run --rm --user 0:0 \
    --env "APP_PASSWORD=${APP_PASSWORD}" \
    --env "ROOT_PASSWORD=${ROOT_PASSWORD}" \
    --volume "${APP_SECRET_VOLUME}:/run/secrets/app" \
    --volume "${ROOT_SECRET_VOLUME}:/run/secrets/root" \
    "$DATABASE_IMAGE" /bin/bash -Eeuo pipefail -c '
        umask 027
        printf %s "$APP_PASSWORD" > /run/secrets/app/MARIADB_PASSWORD
        printf %s "$ROOT_PASSWORD" > /run/secrets/root/MARIADB_ROOT_PASSWORD
        chown 0:999 /run/secrets/app/MARIADB_PASSWORD /run/secrets/root/MARIADB_ROOT_PASSWORD
        chmod 0440 /run/secrets/app/MARIADB_PASSWORD /run/secrets/root/MARIADB_ROOT_PASSWORD
    '

docker run --rm --user 0:0 \
    --volume "${DATABASE_VOLUME}:/var/lib/mysql" \
    "$DATABASE_IMAGE" /bin/bash -Eeuo pipefail -c '
        chown 999:999 /var/lib/mysql
        chmod 0700 /var/lib/mysql
    '

start_database

runtime_id="$(docker exec "$DATABASE_CONTAINER" sh -c 'printf "%s:%s" "$(id -u)" "$(id -g)"')"
test "$runtime_id" = "999:999" || fail "MariaDB did not run as uid/gid 999"
docker exec "$DATABASE_CONTAINER" sh -c '[ "$MARIADB_ROOT_HOST" = localhost ]' \
    || fail "MARIADB_ROOT_HOST is not localhost"

app_secret_metadata="$(docker exec "$DATABASE_CONTAINER" stat -c '%a:%u:%g' /run/secrets/app/MARIADB_PASSWORD)"
root_secret_metadata="$(docker exec "$DATABASE_CONTAINER" stat -c '%a:%u:%g' /run/secrets/root/MARIADB_ROOT_PASSWORD)"
test "$app_secret_metadata" = "$EXPECTED_SECRET_MODE" || fail "application Secret projection metadata is wrong"
test "$root_secret_metadata" = "$EXPECTED_SECRET_MODE" || fail "root Secret projection metadata is wrong"

docker exec --env "MYSQL_PWD=${APP_PASSWORD}" "$DATABASE_CONTAINER" \
    mariadb --host=127.0.0.1 --user="$DATABASE_USER" \
    --execute='CREATE TABLE bench_marker (id INT PRIMARY KEY); INSERT INTO bench_marker VALUES (1);' \
    -- "$DATABASE_NAME"

datadir_entries="$(docker exec "$DATABASE_CONTAINER" find /var/lib/mysql -mindepth 1 -maxdepth 1 -print | wc -l | tr -d '[:space:]')"
test "$datadir_entries" -gt 0 || fail "MariaDB datadir remained empty"

# Recreate the non-root container over the populated datadir. Official init
# variables must not be mistaken for rotation controls on this second start.
docker rm -f "$DATABASE_CONTAINER" >/dev/null
start_database
row_count="$(
    docker exec --env "MYSQL_PWD=${APP_PASSWORD}" "$DATABASE_CONTAINER" \
        mariadb --host=127.0.0.1 --user="$DATABASE_USER" \
        --batch --skip-column-names --execute='SELECT COUNT(*) FROM bench_marker;' \
        -- "$DATABASE_NAME"
)"
test "$row_count" = "1" || fail "populated datadir did not survive container recreation"
printf 'MariaDB runtime: uid/gid=%s appSecret=%s rootSecret=%s datadirEntries=%s recreatedRows=%s\n' \
    "$runtime_id" "$app_secret_metadata" "$root_secret_metadata" "$datadir_entries" "$row_count"

printf 'MariaDB behavior: all runtime properties passed\n'
printf 'Scheduled-backup behavior now lives in db-maintenance-behavior.sh, which\n'
printf 'exercises the shipped lock-wrapped scripts against the same database.\n'
