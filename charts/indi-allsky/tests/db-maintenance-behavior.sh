#!/usr/bin/env bash
# Disposable runtime proof for the shared database-maintenance advisory lock
# (issue #16), the atomic no-clobber dump publication (issue #22), and the edge
# pod's exact-overlay startup barrier (issue #6). Also carries one static
# source-contract check unrelated to those three, for the admin-seed argv
# regression in issue #53 — placed here rather than in a fourth bench because
# it needs no MariaDB and no shipped-script container, only a grep, and this
# file is where the pattern for that kind of check already lives.
#
# These are behaviours, not manifest content: no amount of template assertion
# can show that two jobs actually serialize, that a collision is refused rather
# than silently winning, or that a stale sentinel keeps the daemon waiting. The
# scripts under test are the ones the images ship, mounted at the same paths
# the Dockerfiles install them to, and they run against a real MariaDB.
#
# The container image here is only a host for bash, the mariadb client and
# coreutils — exactly what the shipped scripts need — so this bench does not
# require the chart's own images to have been built.
#
# All credentials are generated test fixtures and are never printed; output is
# limited to non-secret metadata and pass/fail summaries.
#
# Single-quoted command strings are deliberate throughout: they are evaluated
# inside the bench container, where the environment they reference lives, not by
# this shell.
# shellcheck disable=SC2016  # inner-shell strings are expanded in the container
set -Eeuo pipefail

SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIRECTORY="$(cd -- "${SCRIPT_DIRECTORY}/.." && pwd)"
REPOSITORY_DIRECTORY="$(cd -- "${CHART_DIRECTORY}/../.." && pwd)"
BASE_VALUES="${SCRIPT_DIRECTORY}/a5-values.yaml"
RELEASE_NAME="behavior"

BENCH_ID="dbmaint-${$}"
NETWORK_NAME="${BENCH_ID}-network"
DATABASE_CONTAINER="${BENCH_ID}-mariadb"
DATABASE_VOLUME="${BENCH_ID}-database"
BACKUP_VOLUME="${BENCH_ID}-backup"
SCRATCH_DIRECTORY="$(mktemp -d)"

DATABASE_NAME="indi_allsky"
DATABASE_USER="indi_allsky"
DATABASE_PORT="3306"
BACKUP_DIRECTORY="/var/www/html/.state/backups"
STARTUP_ATTEMPTS="120"
STARTUP_DELAY_SECONDS="1"

# Long enough to cross the supervisor's 30-second wait-log cadence, so the
# progress line is observed rather than assumed.
CONTENTION_HOLD_SECONDS="35"
# Short hold for the plain "second actor blocks then proceeds" cases.
SHORT_HOLD_SECONDS="8"
CONCURRENT_PUBLISHERS="4"

# sysexits.h statuses the supervisor promises.
EX_USAGE=64
EX_UNAVAILABLE=69
EX_SIGTERM=143
CHILD_FAILURE_STATUS=7

# Runtime-derived dummy values avoid embedding a credential-like literal in
# tracked source while remaining deterministic within this disposable run.
APP_PASSWORD="$(printf 'db maintenance bench %s' "$BENCH_ID" | sha256sum | cut -c1-24)"

cleanup() {
    docker rm -f "$DATABASE_CONTAINER" >/dev/null 2>&1 || true
    docker network rm "$NETWORK_NAME" >/dev/null 2>&1 || true
    docker volume rm "$DATABASE_VOLUME" "$BACKUP_VOLUME" >/dev/null 2>&1 || true
    rm -rf -- "$SCRATCH_DIRECTORY"
}
trap cleanup EXIT INT TERM HUP

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

# The image is a host for the shipped scripts, not a subject: it is read out of
# the chart so the bench cannot drift onto a different MariaDB than the one the
# release runs.
BENCH_IMAGE="$(
    helm template "$RELEASE_NAME" "$CHART_DIRECTORY" \
        --values "$BASE_VALUES" \
        --show-only templates/mariadb-statefulset.yaml \
        | yq eval -r '.spec.template.spec.containers[0].image' -
)"
test -n "$BENCH_IMAGE" || fail "rendered MariaDB image is empty"

# The chart must invoke exactly these entry points, so the bench and the release
# cannot disagree about what runs.
rendered_command="$(
    helm template "$RELEASE_NAME" "$CHART_DIRECTORY" \
        --values "$BASE_VALUES" \
        --set mariadb.backup.enabled=true \
        --show-only templates/mariadb-backup-cronjob.yaml \
        | yq eval -r '.spec.jobTemplate.spec.template.spec.containers[0].command[0] + " " + (.spec.jobTemplate.spec.template.spec.containers[0].args | join(" "))' -
)"
test "$rendered_command" = "/home/allsky/db-maintenance-lock.sh -- /home/allsky/scheduled-backup.sh" \
    || fail "the backup CronJob does not run the shipped lock-wrapped script"

# Publication must never use a primitive that can replace an existing artifact.
# Comments are stripped first: the file names those primitives in prose in order
# to forbid them, and matching that prose would make this check fire on itself.
publication_code="${SCRATCH_DIRECTORY}/dump-publish.code"
grep -v '^[[:space:]]*#' "${REPOSITORY_DIRECTORY}/images/web/dump-publish.sh" >"$publication_code"
for forbidden in 'mv ' 'install ' 'cp '; do
    if grep -Fq -- "$forbidden" "$publication_code"; then
        fail "dump-publish.sh uses a clobbering publication primitive (${forbidden})"
    fi
done
grep -Fq 'ln -- "$DUMP_TEMPORARY_FILE" "$final_file"' "$publication_code" \
    || fail "dump-publish.sh does not publish by hard link"

# The acquisition deadline is a fixed internal constant, deliberately not a
# public value. Waiting it out would add five minutes to every CI run, so the
# constant is asserted statically and the waiting behaviour dynamically below.
grep -Fq 'LOCK_ACQUIRE_DEADLINE_SECONDS=300' "${REPOSITORY_DIRECTORY}/images/web/db-maintenance-lock.sh" \
    || fail "the advisory-lock acquisition deadline is not the documented 300s"

# Admin seeding must never pass a credential-shaped value as a separate
# argparse argument (issue #53): a generated or operator-chosen password
# starting with "-" (e.g. e2e's generated_secret() base64url alphabet, which
# maps a leading "+" to "-") makes argparse read `-p VALUE` as VALUE looking
# like another flag and reject it with "expected one argument" — a crash loop
# the admin-seed step then never recovers from, since the same bad value is
# re-derived from the same Secret on every restart. `--flag=value` is
# unambiguous regardless of what follows the "=", so each assertion below
# requires the EXACT combined flag+value string: a revert of even one flag
# on either call to the old separate-argument form makes its assertion fail,
# with no separate "forbidden pattern" list needed (an earlier draft of this
# check tried that and matched bash's own `-f`/`-e` file-test operators
# elsewhere in the file — a false positive on unrelated syntax). Static
# rather than a live adduser/argparse run: usertool.py's top-level imports
# need the full application venv this bench's bare MariaDB-based image does
# not carry, and the regression this guards against is purely about argv
# shape, not behavior the database could reveal.
seed_code="${SCRATCH_DIRECTORY}/migrate-critical.code"
grep -v '^[[:space:]]*#' "${REPOSITORY_DIRECTORY}/images/web/migrate-critical.sh" >"$seed_code"
grep -Fq 'usertool.py adduser --username="$INDIALLSKY_WEB_USER" --password="$WEB_PASS"' "$seed_code" \
    || fail "migrate-critical.sh's admin-seed adduser call does not use the argparse-safe --flag=value form"
grep -Fq -- '--fullname="${INDIALLSKY_WEB_NAME:-Admin}" --email="$WEB_EMAIL"' "$seed_code" \
    || fail "migrate-critical.sh's admin-seed fullname/email flags are not the argparse-safe --flag=value form"
grep -Fq 'usertool.py setadmin --username="$INDIALLSKY_WEB_USER"' "$seed_code" \
    || fail "migrate-critical.sh's setadmin call does not use the argparse-safe --flag=value form"

mounted_scripts=(
    "--volume" "${REPOSITORY_DIRECTORY}/images/shared/validators.sh:/home/allsky/validators.sh:ro"
    "--volume" "${REPOSITORY_DIRECTORY}/images/web/db-connection.sh:/home/allsky/db-connection.sh:ro"
    "--volume" "${REPOSITORY_DIRECTORY}/images/web/dump-publish.sh:/home/allsky/dump-publish.sh:ro"
    "--volume" "${REPOSITORY_DIRECTORY}/images/web/db-maintenance-lock.sh:/home/allsky/db-maintenance-lock.sh:ro"
    "--volume" "${REPOSITORY_DIRECTORY}/images/web/scheduled-backup.sh:/home/allsky/scheduled-backup.sh:ro"
    "--volume" "${REPOSITORY_DIRECTORY}/images/daemon/wait-overlay.sh:/home/allsky/wait-overlay.sh:ro"
)

database_environment=(
    "--env" "INDIALLSKY_MARIADB_HOST=${DATABASE_CONTAINER}"
    "--env" "INDIALLSKY_MARIADB_PORT=${DATABASE_PORT}"
    "--env" "INDIALLSKY_MARIADB_SSL=false"
    "--env" "MARIADB_USER=${DATABASE_USER}"
    "--env" "MARIADB_DATABASE=${DATABASE_NAME}"
    "--env" "MARIADB_PASSWORD=${APP_PASSWORD}"
    "--env" "INDIALLSKY_BACKUP_DIR=${BACKUP_DIRECTORY}"
    "--env" "INDIALLSKY_BACKUP_RETENTION_DAYS=14"
)

# $1 = container name ("" for anonymous), remaining = command
run_bench() {
    local name="$1"
    shift
    local name_arguments=()
    if [ -n "$name" ]; then
        name_arguments=(--name "$name")
    fi
    docker run --rm "${name_arguments[@]}" \
        --network "$NETWORK_NAME" \
        --user 10001:10001 \
        --entrypoint /bin/bash \
        "${database_environment[@]}" \
        "${mounted_scripts[@]}" \
        --volume "${BACKUP_VOLUME}:/var/www/html" \
        "$BENCH_IMAGE" "$@"
}

# Same, detached, so a holder can be signalled while it runs.
run_bench_detached() {
    local name="$1"
    shift
    docker run --detach --name "$name" \
        --network "$NETWORK_NAME" \
        --user 10001:10001 \
        --entrypoint /bin/bash \
        "${database_environment[@]}" \
        "${mounted_scripts[@]}" \
        --volume "${BACKUP_VOLUME}:/var/www/html" \
        "$BENCH_IMAGE" "$@" >/dev/null
}

backup_file_count() {
    run_bench "" -c \
        'find "$INDIALLSKY_BACKUP_DIR" -maxdepth 1 -type f -name "indi-allsky_scheduled_*.sql.gz" -print | wc -l' \
        | tr -d '[:space:]'
}

temporary_file_count() {
    run_bench "" -c \
        'find "$INDIALLSKY_BACKUP_DIR" -maxdepth 1 -type f -name ".*.tmp" -print | wc -l' \
        | tr -d '[:space:]'
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
    fail "MariaDB did not become healthy after ${STARTUP_ATTEMPTS} attempts"
}


# --- fixture ----------------------------------------------------------------

docker network create "$NETWORK_NAME" >/dev/null
docker volume create "$DATABASE_VOLUME" >/dev/null
docker volume create "$BACKUP_VOLUME" >/dev/null

docker run --detach \
    --name "$DATABASE_CONTAINER" \
    --network "$NETWORK_NAME" \
    --env "MARIADB_DATABASE=${DATABASE_NAME}" \
    --env "MARIADB_USER=${DATABASE_USER}" \
    --env "MARIADB_PASSWORD=${APP_PASSWORD}" \
    --env "MARIADB_RANDOM_ROOT_PASSWORD=yes" \
    --volume "${DATABASE_VOLUME}:/var/lib/mysql" \
    "$BENCH_IMAGE" >/dev/null
wait_for_database

docker exec --env "MYSQL_PWD=${APP_PASSWORD}" "$DATABASE_CONTAINER" \
    mariadb --host=127.0.0.1 --user="$DATABASE_USER" \
    --execute='CREATE TABLE bench_marker (id INT PRIMARY KEY); INSERT INTO bench_marker VALUES (1);' \
    -- "$DATABASE_NAME"

docker run --rm --user 0:0 \
    --volume "${BACKUP_VOLUME}:/var/www/html" \
    "$BENCH_IMAGE" /bin/bash -Eeuo pipefail -c '
        mkdir -p /var/www/html/.state/backups
        chown -R 10001:10001 /var/www/html
        chmod 0700 /var/www/html/.state/backups
    '


# --- supervisor command grammar and status propagation ----------------------

set +e
run_bench "" /home/allsky/db-maintenance-lock.sh >"${SCRATCH_DIRECTORY}/usage.log" 2>&1
usage_status=$?
set -e
test "$usage_status" -eq "$EX_USAGE" \
    || fail "the lock supervisor did not reject a missing command with status ${EX_USAGE}"
grep -Fq -- '-- <command> [args...]' "${SCRATCH_DIRECTORY}/usage.log" \
    || fail "the usage error did not state the supported grammar"

run_bench "" /home/allsky/db-maintenance-lock.sh -- /bin/bash -c 'echo protected-command-ran' \
    >"${SCRATCH_DIRECTORY}/success.log" 2>&1
grep -Fq 'Holding the database maintenance advisory lock' "${SCRATCH_DIRECTORY}/success.log" \
    || fail "the supervisor did not report acquiring the lock"
grep -Fq 'protected-command-ran' "${SCRATCH_DIRECTORY}/success.log" \
    || fail "the protected command did not run"
grep -Fq 'Released the database maintenance advisory lock' "${SCRATCH_DIRECTORY}/success.log" \
    || fail "the supervisor did not release the lock on success"

set +e
run_bench "" /home/allsky/db-maintenance-lock.sh -- /bin/bash -c "exit ${CHILD_FAILURE_STATUS}" \
    >"${SCRATCH_DIRECTORY}/child-failure.log" 2>&1
child_failure_status=$?
set -e
test "$child_failure_status" -eq "$CHILD_FAILURE_STATUS" \
    || fail "the child's exit status was not propagated exactly"
grep -Fq 'Released the database maintenance advisory lock' "${SCRATCH_DIRECTORY}/child-failure.log" \
    || fail "the supervisor did not release the lock after a failing child"

# Credentials must never reach any output stream, argv or artifact.
if grep -Fq -- "$APP_PASSWORD" "${SCRATCH_DIRECTORY}"/*.log; then
    fail "the supervisor leaked the database password into its output"
fi
printf 'lock supervisor: usage=%s childStatus=%s releaseOnSuccess=yes releaseOnFailure=yes credentialLeak=no\n' \
    "$usage_status" "$child_failure_status"


# --- serialization, both overlap orders -------------------------------------

# Order 1: the migration-shaped holder starts first; the scheduled backup must
# block until it releases, then complete.
run_bench_detached "${BENCH_ID}-holder-1" \
    /home/allsky/db-maintenance-lock.sh -- /bin/bash -c "sleep ${SHORT_HOLD_SECONDS}"
sleep 2
migration_first_start="$(date +%s)"
run_bench "" /home/allsky/db-maintenance-lock.sh -- /home/allsky/scheduled-backup.sh \
    >"${SCRATCH_DIRECTORY}/order-1-backup.log" 2>&1 \
    || fail "the scheduled backup failed while waiting behind a migration"
migration_first_waited=$(( $(date +%s) - migration_first_start ))
docker rm -f "${BENCH_ID}-holder-1" >/dev/null 2>&1 || true
test "$migration_first_waited" -ge $((SHORT_HOLD_SECONDS - 3)) \
    || fail "the scheduled backup entered its critical section while a migration held the lock"
grep -Fq 'Verified database dump published' "${SCRATCH_DIRECTORY}/order-1-backup.log" \
    || fail "the scheduled backup did not publish after acquiring the lock"

# Order 2: the backup holds the lock through its whole critical section; a
# migration-shaped actor must block behind it.
run_bench_detached "${BENCH_ID}-holder-2" \
    /home/allsky/db-maintenance-lock.sh -- /bin/bash -c \
    "/home/allsky/scheduled-backup.sh; sleep ${SHORT_HOLD_SECONDS}"
sleep 3
backup_first_start="$(date +%s)"
run_bench "" /home/allsky/db-maintenance-lock.sh -- /bin/bash -c 'echo migration-critical-section' \
    >"${SCRATCH_DIRECTORY}/order-2-migration.log" 2>&1 \
    || fail "the migration failed while waiting behind a scheduled backup"
backup_first_waited=$(( $(date +%s) - backup_first_start ))
docker rm -f "${BENCH_ID}-holder-2" >/dev/null 2>&1 || true
test "$backup_first_waited" -ge $((SHORT_HOLD_SECONDS - 4)) \
    || fail "the migration entered its critical section while a scheduled backup held the lock"
grep -Fq 'migration-critical-section' "${SCRATCH_DIRECTORY}/order-2-migration.log" \
    || fail "the migration never entered its critical section after the lock was released"
printf 'lock serialization: migrationFirstWait=%ss backupFirstWait=%ss bothOrders=serialized\n' \
    "$migration_first_waited" "$backup_first_waited"

# Bounded, diagnostic waiting: the progress line must appear while blocked.
run_bench_detached "${BENCH_ID}-holder-3" \
    /home/allsky/db-maintenance-lock.sh -- /bin/bash -c "sleep ${CONTENTION_HOLD_SECONDS}"
sleep 2
run_bench "" /home/allsky/db-maintenance-lock.sh -- /bin/bash -c 'true' \
    >"${SCRATCH_DIRECTORY}/wait-progress.log" 2>&1 \
    || fail "the waiting actor did not eventually acquire the lock"
docker rm -f "${BENCH_ID}-holder-3" >/dev/null 2>&1 || true
grep -Eq 'Still waiting for database maintenance advisory lock \(30s elapsed\)' \
    "${SCRATCH_DIRECTORY}/wait-progress.log" \
    || fail "the supervisor did not log progress while waiting for the lock"
printf 'lock diagnostics: progressLoggedAt=30s acquisitionDeadline=300s\n'


# --- release on SIGTERM ------------------------------------------------------

run_bench_detached "${BENCH_ID}-signalled" \
    /home/allsky/db-maintenance-lock.sh -- /bin/bash -c 'sleep 300'
sleep 4
docker kill -s TERM "${BENCH_ID}-signalled" >/dev/null
for _ in $(seq 1 20); do
    if [ "$(docker inspect -f '{{.State.Running}}' "${BENCH_ID}-signalled" 2>/dev/null || echo false)" = false ]; then
        break
    fi
    sleep 1
done
signalled_status="$(docker inspect -f '{{.State.ExitCode}}' "${BENCH_ID}-signalled" 2>/dev/null || echo unknown)"
docker logs "${BENCH_ID}-signalled" >"${SCRATCH_DIRECTORY}/signalled.log" 2>&1 || true
docker rm -f "${BENCH_ID}-signalled" >/dev/null 2>&1 || true
test "$signalled_status" = "$EX_SIGTERM" \
    || fail "a handled SIGTERM did not produce status ${EX_SIGTERM}"
grep -Fq 'Released the database maintenance advisory lock' "${SCRATCH_DIRECTORY}/signalled.log" \
    || fail "the supervisor did not release the lock on SIGTERM"

# The definitive proof that the lock is free: another actor takes it at once.
reacquire_start="$(date +%s)"
run_bench "" /home/allsky/db-maintenance-lock.sh -- /bin/bash -c 'true' >/dev/null 2>&1 \
    || fail "the lock could not be reacquired after a signalled holder exited"
reacquire_seconds=$(( $(date +%s) - reacquire_start ))
test "$reacquire_seconds" -lt "$SHORT_HOLD_SECONDS" \
    || fail "reacquiring the lock after SIGTERM took as long as a contended acquisition"
printf 'lock release: signalStatus=%s releasedOnSignal=yes reacquiredIn=%ss\n' \
    "$signalled_status" "$reacquire_seconds"


# --- atomic, collision-resistant publication ---------------------------------

published_before="$(backup_file_count)"
for _ in $(seq 1 "$CONCURRENT_PUBLISHERS"); do
    run_bench "" /home/allsky/scheduled-backup.sh >/dev/null 2>&1 &
done
wait
published_after="$(backup_file_count)"
test "$published_after" -eq $((published_before + CONCURRENT_PUBLISHERS)) \
    || fail "concurrent publications did not create ${CONCURRENT_PUBLISHERS} distinct final files"
test "$(temporary_file_count)" -eq 0 \
    || fail "concurrent publications left a temporary file behind"

run_bench "" -Eeuo pipefail -c '
    for artifact in "$INDIALLSKY_BACKUP_DIR"/indi-allsky_scheduled_*.sql.gz; do
        gzip -t "$artifact"
        test "$(stat -c "%a:%u:%g:%h" "$artifact")" = "600:10001:10001:1"
    done
    test "$(stat -c "%a" "$INDIALLSKY_BACKUP_DIR")" = "700"
    sample="$(find "$INDIALLSKY_BACKUP_DIR" -maxdepth 1 -name "indi-allsky_scheduled_*.sql.gz" -print -quit)"
    test -n "$sample"
    # Consume the whole stream: grep -q can exit early and turn a valid
    # producer into SIGPIPE/141 under pipefail.
    gzip -cd "$sample" | grep -F bench_marker >/dev/null
' || fail "a published artifact was not a private, single-linked, complete dump of the database"
printf 'atomic publication: concurrent=%s distinctFinals=%s tempFiles=0 mode=600 links=1 gzip=valid\n' \
    "$CONCURRENT_PUBLISHERS" "$CONCURRENT_PUBLISHERS"

# A final-name collision must be a nonzero error that preserves the existing
# artifact byte for byte. Real collisions are made unreachable by the timestamp
# plus mktemp's suffix, so the bench pins both with stand-ins EARLIER ON PATH.
# Those substitute coreutils tools; the shipped script runs unmodified.
mkdir -p "${SCRATCH_DIRECTORY}/collision-bin"
cat >"${SCRATCH_DIRECTORY}/collision-bin/mktemp" <<'FAKE_MKTEMP'
#!/bin/bash
# Deterministic stand-in so two runs choose the same temporary name.
printf '%s\n' "${INDIALLSKY_BACKUP_DIR}/.collision-fixture.tmp"
: >"${INDIALLSKY_BACKUP_DIR}/.collision-fixture.tmp"
chmod 0600 "${INDIALLSKY_BACKUP_DIR}/.collision-fixture.tmp"
FAKE_MKTEMP
cat >"${SCRATCH_DIRECTORY}/collision-bin/date" <<'FAKE_DATE'
#!/bin/bash
# Freezes the artifact timestamp so two runs choose the same final name.
printf '%s\n' 20260101T000000Z
FAKE_DATE
chmod 0755 "${SCRATCH_DIRECTORY}/collision-bin/mktemp" "${SCRATCH_DIRECTORY}/collision-bin/date"

collision_first_log="${SCRATCH_DIRECTORY}/collision-first.log"
collision_second_log="${SCRATCH_DIRECTORY}/collision-second.log"
docker run --rm --network "$NETWORK_NAME" --user 10001:10001 --entrypoint /bin/bash \
    "${database_environment[@]}" "${mounted_scripts[@]}" \
    --volume "${BACKUP_VOLUME}:/var/www/html" \
    --volume "${SCRATCH_DIRECTORY}/collision-bin:/bench/bin:ro" \
    --env "PATH=/bench/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    "$BENCH_IMAGE" /home/allsky/scheduled-backup.sh >"$collision_first_log" 2>&1 \
    || fail "the pinned-name publication did not succeed the first time"
collided_file="$(grep -o '/var/www/html/[^ ]*\.sql\.gz' "$collision_first_log" | head -1)"
test -n "$collided_file" || fail "the first pinned-name run reported no final artifact"

collided_checksum_before="$(
    run_bench "" -c "sha256sum < '${collided_file}'" | cut -d' ' -f1
)"
set +e
docker run --rm --network "$NETWORK_NAME" --user 10001:10001 --entrypoint /bin/bash \
    "${database_environment[@]}" "${mounted_scripts[@]}" \
    --volume "${BACKUP_VOLUME}:/var/www/html" \
    --volume "${SCRATCH_DIRECTORY}/collision-bin:/bench/bin:ro" \
    --env "PATH=/bench/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    "$BENCH_IMAGE" /home/allsky/scheduled-backup.sh >"$collision_second_log" 2>&1
collision_status=$?
set -e
if [ "$collision_status" -eq 0 ]; then
    printf -- '--- first run ---\n' >&2
    cat "$collision_first_log" >&2
    printf -- '--- second run ---\n' >&2
    cat "$collision_second_log" >&2
    fail "a final-name collision was not treated as an error"
fi
grep -Fq 'refusing to replace an existing dump' "$collision_second_log" \
    || fail "the collision error did not name the refusal to replace an artifact"
collided_checksum_after="$(
    run_bench "" -c "sha256sum < '${collided_file}'" | cut -d' ' -f1
)"
test "$collided_checksum_before" = "$collided_checksum_after" \
    || fail "a collision replaced the existing artifact's bytes"
test "$(temporary_file_count)" -eq 0 \
    || fail "the collision path left a temporary file behind"
printf 'collision safety: status=%s existingArtifact=preserved tempFiles=0\n' "$collision_status"


# --- failure never publishes, never prunes ----------------------------------

run_bench "" -Eeuo pipefail -c '
    printf must-survive | gzip -c > "$INDIALLSKY_BACKUP_DIR/indi-allsky_scheduled_expired.sql.gz"
    printf must-survive | gzip -c > "$INDIALLSKY_BACKUP_DIR/pre-migrate_expired.sql.gz"
    chmod 0600 "$INDIALLSKY_BACKUP_DIR"/*_expired.sql.gz
    touch -d "30 days ago" "$INDIALLSKY_BACKUP_DIR"/*_expired.sql.gz
'
before_failure="$(backup_file_count)"

# A lock that cannot be taken must stop the run before any dump work. Pointing
# the maintenance environment at a database this account cannot open makes the
# supervisor's own session unusable, which is the safety control failing rather
# than the child.
set +e
docker run --rm --network "$NETWORK_NAME" --user 10001:10001 --entrypoint /bin/bash \
    "${database_environment[@]}" "${mounted_scripts[@]}" \
    --env "MARIADB_DATABASE=missing_database" \
    --volume "${BACKUP_VOLUME}:/var/www/html" \
    "$BENCH_IMAGE" /home/allsky/db-maintenance-lock.sh -- /home/allsky/scheduled-backup.sh \
    >"${SCRATCH_DIRECTORY}/lock-failure.log" 2>&1
lock_failure_status=$?
set -e
test "$lock_failure_status" -eq "$EX_UNAVAILABLE" \
    || fail "an unusable lock session did not exit with the safety-control status ${EX_UNAVAILABLE}"
test "$(backup_file_count)" -eq "$before_failure" \
    || fail "a run whose lock could not be taken still published an artifact"
test "$(temporary_file_count)" -eq 0 \
    || fail "a run whose lock could not be taken left a temporary file behind"
printf 'lock acquisition failure: status=%s published=0 tempFiles=0\n' "$lock_failure_status"

# A dump that fails while the lock IS held must leave nothing behind, skip
# retention, and still release the lock. A stand-in mariadb-dump earlier on PATH
# produces the failure; the shipped script runs unmodified.
mkdir -p "${SCRATCH_DIRECTORY}/failure-bin"
cat >"${SCRATCH_DIRECTORY}/failure-bin/mariadb-dump" <<'FAKE_DUMP'
#!/bin/bash
# Stand-in for a dump that dies mid-stream.
printf 'stand-in dump failure\n' >&2
exit 2
FAKE_DUMP
chmod 0755 "${SCRATCH_DIRECTORY}/failure-bin/mariadb-dump"

set +e
docker run --rm --network "$NETWORK_NAME" --user 10001:10001 --entrypoint /bin/bash \
    "${database_environment[@]}" "${mounted_scripts[@]}" \
    --volume "${BACKUP_VOLUME}:/var/www/html" \
    --volume "${SCRATCH_DIRECTORY}/failure-bin:/bench/bin:ro" \
    --env "PATH=/bench/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    "$BENCH_IMAGE" /home/allsky/db-maintenance-lock.sh -- /home/allsky/scheduled-backup.sh \
    >"${SCRATCH_DIRECTORY}/dump-failure.log" 2>&1
dump_failure_status=$?
set -e
test "$dump_failure_status" -ne 0 || fail "a failed dump reported success"
test "$(backup_file_count)" -eq "$before_failure" \
    || fail "a failed dump published a final artifact"
test "$(temporary_file_count)" -eq 0 \
    || fail "a failed dump left a temporary file behind"
run_bench "" -c 'test -e "$INDIALLSKY_BACKUP_DIR/indi-allsky_scheduled_expired.sql.gz"' \
    || fail "a failed dump ran retention"
grep -Fq 'Released the database maintenance advisory lock' "${SCRATCH_DIRECTORY}/dump-failure.log" \
    || fail "the supervisor did not release the lock after a failed dump"
printf 'dump failure: status=%s published=0 tempFiles=0 retentionRan=no lockReleased=yes\n' \
    "$dump_failure_status"

# Retention is prefix-scoped: a successful scheduled run prunes its own expired
# artifact and never the pre-migration recovery set.
run_bench "" /home/allsky/db-maintenance-lock.sh -- /home/allsky/scheduled-backup.sh >/dev/null 2>&1 \
    || fail "the scheduled backup failed after the dump-failure case"
run_bench "" -Eeuo pipefail -c '
    test ! -e "$INDIALLSKY_BACKUP_DIR/indi-allsky_scheduled_expired.sql.gz"
    test -e "$INDIALLSKY_BACKUP_DIR/pre-migrate_expired.sql.gz"
' || fail "retention did not stay inside its own prefix"
printf 'retention isolation: scheduledExpired=pruned preMigrate=untouched\n'


# --- edge startup barrier ----------------------------------------------------

# The daemon image's wait script, exercised against real files. `sleep` is
# replaced so the fixed 120-attempt loop finishes quickly; the checksum parsing,
# the file reads and every diagnostic are the real ones.
mkdir -p "${SCRATCH_DIRECTORY}/barrier-bin"
cat >"${SCRATCH_DIRECTORY}/barrier-bin/sleep" <<'FAKE_SLEEP'
#!/bin/bash
# Advances the shipped script's fixed retry loop without waiting for it.
exit 0
FAKE_SLEEP
chmod 0755 "${SCRATCH_DIRECTORY}/barrier-bin/sleep"

EXPECTED_CHECKSUM="$(printf 'expected overlay' | sha256sum | cut -d' ' -f1)"
STALE_CHECKSUM="$(printf 'previous overlay' | sha256sum | cut -d' ' -f1)"

run_barrier() {  # $1 = sentinel body written with printf, or the literal ABSENT
    docker run --rm --user 10001:10001 --entrypoint /bin/bash \
        "${mounted_scripts[@]}" \
        --volume "${SCRATCH_DIRECTORY}/barrier-bin:/bench/bin:ro" \
        --env "PATH=/bench/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
        --env "INDIALLSKY_CONFIG_OVERLAY_SHA256=${EXPECTED_CHECKSUM}" \
        --env "INDIALLSKY_CONFIG_OVERLAY_APPLIED_SENTINEL=/tmp/state/config-overlay.applied" \
        --env "SENTINEL_BODY=$1" \
        "$BENCH_IMAGE" -Eeuo pipefail -c '
            mkdir -p "$(dirname "$INDIALLSKY_CONFIG_OVERLAY_APPLIED_SENTINEL")"
            if [ "$SENTINEL_BODY" != ABSENT ]; then
                printf "%b" "$SENTINEL_BODY" > "$INDIALLSKY_CONFIG_OVERLAY_APPLIED_SENTINEL"
            fi
            exec /home/allsky/wait-overlay.sh
        '
}

barrier_state() {  # $1 = sentinel body, $2 = expected last state
    local body="$1" expected="$2" log status
    log="${SCRATCH_DIRECTORY}/barrier-${expected}.log"
    set +e
    run_barrier "$body" >"$log" 2>&1
    status=$?
    set -e
    test "$status" -ne 0 || fail "the startup barrier passed on a ${expected} sentinel"
    if ! grep -Fq "(last state: ${expected})" "$log"; then
        cat "$log" >&2
        fail "the startup barrier did not diagnose a ${expected} sentinel distinctly"
    fi
}

barrier_state ABSENT missing
barrier_state '' empty
barrier_state 'not-a-checksum\n' malformed
barrier_state "${STALE_CHECKSUM}\n" stale
# Exactly one trailing newline is stripped, so two is malformed rather than a
# lenient match.
barrier_state "${EXPECTED_CHECKSUM}\n\n" malformed

run_barrier "${EXPECTED_CHECKSUM}\n" >"${SCRATCH_DIRECTORY}/barrier-match.log" 2>&1 \
    || fail "the startup barrier rejected an exactly matching sentinel"
grep -Fq 'edge startup gate passed' "${SCRATCH_DIRECTORY}/barrier-match.log" \
    || fail "the startup barrier did not report passing"

# Bounded: the exhausted loop exits non-zero rather than waiting forever, and
# says how long it waited.
grep -Fq 'did not match after 600s' "${SCRATCH_DIRECTORY}/barrier-stale.log" \
    || fail "the startup barrier did not report its fixed 600s budget"
grep -Eq 'Still waiting for the applied-overlay checksum sentinel \(60s elapsed' \
    "${SCRATCH_DIRECTORY}/barrier-stale.log" \
    || fail "the startup barrier did not log progress at least once per minute"
printf 'startup barrier: missing/empty/malformed/stale/doubleNewline=distinct match=passed bounded=600s\n'

printf 'database maintenance behavior: all runtime properties passed\n'
