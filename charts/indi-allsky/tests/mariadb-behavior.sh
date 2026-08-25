#!/usr/bin/env bash
# Disposable runtime proof for the chart's MariaDB file-secret and verified
# backup contracts. All credentials are generated test fixtures and are never
# printed; output is limited to non-secret metadata and pass/fail summaries.
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
BACKUP_VOLUME="${BENCH_ID}-backup"
SCRATCH_DIRECTORY="$(mktemp -d)"
BACKUP_SCRIPT="${SCRATCH_DIRECTORY}/backup.sh"

DATABASE_NAME="-allsky"
DATABASE_USER="indi_allsky"
DATABASE_PORT="3306"
BACKUP_DIRECTORY="/var/www/html/.state/backups"
BACKUP_PREFIX="indi-allsky_scheduled"
RETENTION_DAYS="14"
EXPECTED_SECRET_MODE="440:0:999"
EXPECTED_BACKUP_DIRECTORY_MODE="700:10001:10001"
EXPECTED_BACKUP_FILE_MODE="600:10001:10001"
STARTUP_ATTEMPTS="120"
STARTUP_DELAY_SECONDS="1"
SAME_SECOND_ATTEMPTS="5"

# Runtime-derived dummy values avoid embedding a credential-like literal in
# tracked source while remaining deterministic within this disposable run.
APP_PASSWORD="$(printf 'A5 application bench %s' "$BENCH_ID" | sha256sum | cut -c1-24)"
ROOT_PASSWORD="$(printf 'A5 root bench %s' "$BENCH_ID" | sha256sum | cut -c1-24)"

cleanup() {
    docker rm -f "$DATABASE_CONTAINER" >/dev/null 2>&1 || true
    docker network rm "$NETWORK_NAME" >/dev/null 2>&1 || true
    docker volume rm \
        "$DATABASE_VOLUME" "$APP_SECRET_VOLUME" "$ROOT_SECRET_VOLUME" \
        "$BACKUP_VOLUME" >/dev/null 2>&1 || true
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

scheduled_count() {
    docker run --rm --user 10001:10001 \
        --env "BACKUP_DIR=${BACKUP_DIRECTORY}" \
        --env "SCHEDULED_BACKUP_PREFIX=${BACKUP_PREFIX}" \
        --volume "${BACKUP_VOLUME}:/var/www/html" \
        "$DATABASE_IMAGE" /bin/bash -Eeuo pipefail -c \
        'find "$BACKUP_DIR" -maxdepth 1 -type f -name "${SCHEDULED_BACKUP_PREFIX}_*.sql.gz" -print | wc -l'
}

run_backup() {
    local database="$1"
    local log_file="$2"
    docker run --rm \
        --network "$NETWORK_NAME" \
        --user 10001:10001 \
        --env "DB_HOST=${DATABASE_CONTAINER}" \
        --env "DB_PORT=${DATABASE_PORT}" \
        --env "DB_USER=${DATABASE_USER}" \
        --env "DB_DATABASE=${database}" \
        --env "MYSQL_PWD=${APP_PASSWORD}" \
        --env "BACKUP_DIR=${BACKUP_DIRECTORY}" \
        --env "RETENTION_DAYS=${RETENTION_DAYS}" \
        --env "SCHEDULED_BACKUP_PREFIX=${BACKUP_PREFIX}" \
        --env BACKUP_DIR_MODE=0700 \
        --env BACKUP_FILE_MODE=0600 \
        --volume "${BACKUP_VOLUME}:/var/www/html" \
        --volume "${BACKUP_SCRIPT}:/bench/backup.sh:ro" \
        "$DATABASE_IMAGE" /bin/bash /bench/backup.sh >"$log_file" 2>&1
}

docker network create "$NETWORK_NAME" >/dev/null
docker volume create "$DATABASE_VOLUME" >/dev/null
docker volume create "$APP_SECRET_VOLUME" >/dev/null
docker volume create "$ROOT_SECRET_VOLUME" >/dev/null
docker volume create "$BACKUP_VOLUME" >/dev/null

DATABASE_IMAGE="$(
    helm template "$RELEASE_NAME" "$CHART_DIRECTORY" \
        --values "$BASE_VALUES" \
        --show-only templates/mariadb-statefulset.yaml \
        | yq eval -r '.spec.template.spec.containers[0].image' -
)"
test -n "$DATABASE_IMAGE" || fail "rendered MariaDB image is empty"

helm template "$RELEASE_NAME" "$CHART_DIRECTORY" \
    --values "$BASE_VALUES" \
    --set mariadb.backup.enabled=true \
    --set-string "mariadb.database=${DATABASE_NAME}" \
    --show-only templates/mariadb-backup-cronjob.yaml \
    | yq eval -r '.spec.jobTemplate.spec.template.spec.containers[0].args[0]' - \
        >"$BACKUP_SCRIPT"
chmod 0444 "$BACKUP_SCRIPT"
grep -Fq -- "-- \"\$DB_DATABASE\"" "$BACKUP_SCRIPT" \
    || fail "rendered backup script lacks the database option delimiter"

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
    --volume "${BACKUP_VOLUME}:/var/www/html" \
    "$DATABASE_IMAGE" /bin/bash -Eeuo pipefail -c '
        chown 999:999 /var/lib/mysql
        chmod 0700 /var/lib/mysql
        mkdir -p /var/www/html/.state/backups
        chown -R 10001:10001 /var/www/html
        chmod 0700 /var/www/html/.state/backups
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

# Seed one old scheduled file and one old pre-migrate file. A successful backup
# must prune only the scheduled prefix.
docker run --rm --user 10001:10001 \
    --env "BACKUP_DIR=${BACKUP_DIRECTORY}" \
    --volume "${BACKUP_VOLUME}:/var/www/html" \
    "$DATABASE_IMAGE" /bin/bash -Eeuo pipefail -c '
        printf old-scheduled | gzip -c > "$BACKUP_DIR/indi-allsky_scheduled_old.sql.gz"
        printf old-pre-migrate | gzip -c > "$BACKUP_DIR/pre-migrate_old.sql.gz"
        chmod 0600 "$BACKUP_DIR/indi-allsky_scheduled_old.sql.gz" "$BACKUP_DIR/pre-migrate_old.sql.gz"
        touch -d "30 days ago" "$BACKUP_DIR/indi-allsky_scheduled_old.sql.gz" "$BACKUP_DIR/pre-migrate_old.sql.gz"
    '

FIRST_SUCCESS_LOG="${SCRATCH_DIRECTORY}/first-success.log"
run_backup "$DATABASE_NAME" "$FIRST_SUCCESS_LOG"
grep -Eq '^Verified scheduled database backup: /var/www/html/\.state/backups/indi-allsky_scheduled_[^ ]+\.sql\.gz \([1-9][0-9]* bytes\)$' \
    "$FIRST_SUCCESS_LOG" || fail "success log omitted the verified path or byte size"

docker run --rm --user 10001:10001 \
    --env "BACKUP_DIR=${BACKUP_DIRECTORY}" \
    --volume "${BACKUP_VOLUME}:/var/www/html" \
    "$DATABASE_IMAGE" /bin/bash -Eeuo pipefail -c '
        test ! -e "$BACKUP_DIR/indi-allsky_scheduled_old.sql.gz"
        test -e "$BACKUP_DIR/pre-migrate_old.sql.gz"
        final_file="$(find "$BACKUP_DIR" -maxdepth 1 -type f -name "indi-allsky_scheduled_*.sql.gz" -print -quit)"
        test -n "$final_file"
        test "$(stat -c "%a:%u:%g" "$BACKUP_DIR")" = "700:10001:10001"
        test "$(stat -c "%a:%u:%g" "$final_file")" = "600:10001:10001"
        gzip -t "$final_file"
        # Consume the complete gzip stream: grep -q can exit early and turn a
        # valid producer into SIGPIPE/141 under pipefail.
        gzip -cd "$final_file" | grep -F bench_marker >/dev/null
    ' || fail "backup integrity, modes, or prefix isolation failed"

directory_metadata="$(
    docker run --rm --user 10001:10001 \
        --volume "${BACKUP_VOLUME}:/var/www/html" "$DATABASE_IMAGE" \
        stat -c '%a:%u:%g' "$BACKUP_DIRECTORY"
)"
test "$directory_metadata" = "$EXPECTED_BACKUP_DIRECTORY_MODE" || fail "backup directory metadata is wrong"
printf 'Backup success: database=%s positional=yes directory=%s file=%s gzip=valid marker=present log=verified prefixIsolation=passed\n' \
    "$DATABASE_NAME" "$directory_metadata" "$EXPECTED_BACKUP_FILE_MODE"

# Each concurrent pair must add two files. Retry only to avoid the natural UTC
# second boundary; no clock or command is mocked.
same_second_proven=false
for ((attempt = 1; attempt <= SAME_SECOND_ATTEMPTS; attempt++)); do
    count_before="$(scheduled_count | tr -d '[:space:]')"
    run_backup "$DATABASE_NAME" "${SCRATCH_DIRECTORY}/parallel-${attempt}-a.log" &
    first_pid=$!
    run_backup "$DATABASE_NAME" "${SCRATCH_DIRECTORY}/parallel-${attempt}-b.log" &
    second_pid=$!
    wait "$first_pid"
    wait "$second_pid"
    count_after="$(scheduled_count | tr -d '[:space:]')"
    test "$count_after" -eq $((count_before + 2)) \
        || fail "concurrent backups did not create two distinct final files"

    if docker run --rm --user 10001:10001 \
        --volume "${BACKUP_VOLUME}:/var/www/html" \
        "$DATABASE_IMAGE" find "$BACKUP_DIRECTORY" -maxdepth 1 -type f \
            -name "${BACKUP_PREFIX}_*.sql.gz" -printf '%f\n' \
        | sed -E 's/^indi-allsky_scheduled_([0-9]{8}T[0-9]{6}Z)_.*/\1/' \
        | sort \
        | uniq -c \
        | awk '$1 >= 2 { found=1 } END { exit !found }'; then
        same_second_proven=true
        break
    fi
done
test "$same_second_proven" = true || fail "could not observe two unique same-second final files"
printf 'Backup uniqueness: sameSecond=yes distinctFinals=yes scheduledFileCount=%s\n' "$count_after"

# A failed dump must leave neither a final nor a temporary file and must not run
# retention. Add an already-expired scheduled marker immediately before it.
docker run --rm --user 10001:10001 \
    --env "BACKUP_DIR=${BACKUP_DIRECTORY}" \
    --volume "${BACKUP_VOLUME}:/var/www/html" \
    "$DATABASE_IMAGE" /bin/bash -Eeuo pipefail -c '
        printf must-survive-failure | gzip -c > "$BACKUP_DIR/indi-allsky_scheduled_failure-retention.sql.gz"
        chmod 0600 "$BACKUP_DIR/indi-allsky_scheduled_failure-retention.sql.gz"
        touch -d "30 days ago" "$BACKUP_DIR/indi-allsky_scheduled_failure-retention.sql.gz"
    '

count_before_failure="$(scheduled_count | tr -d '[:space:]')"
set +e
run_backup "missing_database" "${SCRATCH_DIRECTORY}/expected-failure.log"
failure_status=$?
set -e
test "$failure_status" -ne 0 || fail "missing database backup unexpectedly succeeded"
count_after_failure="$(scheduled_count | tr -d '[:space:]')"
test "$count_after_failure" -eq "$count_before_failure" || fail "failed dump changed the final-file count"

docker run --rm --user 10001:10001 \
    --env "BACKUP_DIR=${BACKUP_DIRECTORY}" \
    --volume "${BACKUP_VOLUME}:/var/www/html" \
    "$DATABASE_IMAGE" /bin/bash -Eeuo pipefail -c '
        test -e "$BACKUP_DIR/indi-allsky_scheduled_failure-retention.sql.gz"
        test -e "$BACKUP_DIR/pre-migrate_old.sql.gz"
        test -z "$(find "$BACKUP_DIR" -maxdepth 1 -type f -name ".*.tmp" -print -quit)"
    ' || fail "failed dump left a temp/final artifact or ran retention"

final_file_metadata="$(
    docker run --rm --user 10001:10001 \
        --env "BACKUP_DIR=${BACKUP_DIRECTORY}" \
        --volume "${BACKUP_VOLUME}:/var/www/html" \
        "$DATABASE_IMAGE" /bin/bash -Eeuo pipefail -c '
            final_file="$(find "$BACKUP_DIR" -maxdepth 1 -type f -name "indi-allsky_scheduled_*.sql.gz" ! -name "*failure-retention*" -print -quit)"
            stat -c "%a:%u:%g" "$final_file"
        '
)"
test "$final_file_metadata" = "$EXPECTED_BACKUP_FILE_MODE" || fail "backup file metadata is wrong"

printf 'Backup failure: status=%s finalsBefore=%s finalsAfter=%s tempFiles=0 retentionRan=no\n' \
    "$failure_status" "$count_before_failure" "$count_after_failure"
printf 'Backup behavior: all runtime properties passed\n'
