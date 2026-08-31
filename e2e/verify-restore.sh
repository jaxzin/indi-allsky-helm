#!/usr/bin/env bash
# Executable proof of the operator restore procedure documented in
# docs/configuration.md ("Backup protection and restore").
#
# The chart deliberately renders no restore Job in v1, so there is nothing here
# to unit-test: the procedure IS prose until something runs it. This scenario
# runs it — quiesce writers, take a gzip-verified scheduled dump, destroy the
# database for real, prepare the target schema and grants as root, restore, and
# bring the workloads back with the SAME application Secret — and then proves
# the application can read both the restored configuration and the restored
# image catalogue.
#
# Two failure modes are exercised as well as the happy path, because a restore
# procedure that only works when nothing is wrong is not a procedure. Both are
# checked for credential leakage explicitly: a restore is exactly the moment an
# operator pastes diagnostics into a ticket.
#
# Root isolation is asserted throughout rather than assumed. Every root
# operation runs inside the database container, reading the password from its
# own projected Secret file into MYSQL_PWD; no application or backup workload
# ever mounts that Secret, and this script checks that claim against the live
# pod specs rather than restating it.
#
# Single-quoted in-pod command strings are expanded in the pod, not here.
# shellcheck disable=SC2016  # in-pod strings are expanded in the pod
set -Eeuo pipefail

SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=e2e/lib.sh
# shellcheck disable=SC1091  # resolved only when shellcheck is run with -x over the whole directory
source "${SCRIPT_DIRECTORY}/lib.sh"

SCHEDULED_DUMP_PREFIX="indi-allsky_scheduled"
RESTORE_JOB="e2e-restore-backup"
JOB_COMPLETION_TIMEOUT="600s"
WORKLOAD_ROLLOUT_TIMEOUT="900s"
LOCAL_FORWARD_PORT=18081
CURL_MAX_TIME_SECONDS=20
LATEST_HISTORY_SECONDS=86400
# The connection charset and collation the chart's own environment declares;
# recreating the schema with anything else would be a silently different target.
TARGET_CHARSET="utf8mb4"
TARGET_COLLATION="utf8mb4_unicode_ci"
HIDDEN_MIGRATION_SUFFIX=".e2e-hidden"

SCRATCH_DIRECTORY="$(mktemp -d)"
FORWARD_PID=""
cleanup() {
    if [ -n "$FORWARD_PID" ]; then
        kill "$FORWARD_PID" 2>/dev/null || true
        wait "$FORWARD_PID" 2>/dev/null || true
    fi
    k delete job "$RESTORE_JOB" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    k patch cronjob "$(backup_cronjob)" --type merge --patch '{"spec":{"suspend":false}}' >/dev/null 2>&1 || true
    rm -rf -- "$SCRATCH_DIRECTORY"
}
trap cleanup EXIT INT TERM HUP

workbench_apply
WEB_DEPLOYMENT="$(web_deployment)"
EDGE_DEPLOYMENT="$(edge_deployment)"
CRONJOB_NAME="$(backup_cronjob)"
APP_SECRET="$(app_secret_name)"
ROOT_SECRET="$(root_secret_name)"


# --- root Secret isolation ---------------------------------------------------

section "The MariaDB root Secret reaches only the database pod"

assert_root_secret_isolated() {
    local offenders
    offenders="$(k get pods --selector "app.kubernetes.io/instance=${RELEASE}" --output json \
        | jq -r --arg secret "$ROOT_SECRET" --arg component mariadb '
            .items[]
            | select(.metadata.labels["app.kubernetes.io/component"] != $component)
            | . as $pod
            | [
                (($pod.spec.volumes // [])[] | select(.secret.secretName == $secret) | "volume"),
                ((($pod.spec.containers // []) + ($pod.spec.initContainers // []))[]
                 | (.env // [])[] | select(.valueFrom.secretKeyRef.name == $secret) | "env"),
                ((($pod.spec.containers // []) + ($pod.spec.initContainers // []))[]
                 | (.envFrom // [])[] | select(.secretRef.name == $secret) | "envFrom")
              ][] as $how
            | "\($pod.metadata.name) (\($how))"')"
    test -z "$offenders" \
        || fail "these non-database pods reference the MariaDB root Secret: ${offenders}"
}
assert_root_secret_isolated
pass "no application, backup or workbench pod references ${ROOT_SECRET}"


# --- pre-restore state -------------------------------------------------------

section "Quiesce writers and take a verified scheduled dump"

image_rows_at_start="$(db_row_count image)"
test "$image_rows_at_start" -gt 0 \
    || fail "there are no image rows to lose and recover; run the pipeline scenario first"

# The capture daemon is the only writer of image rows, so it is stopped BEFORE
# the dump. A dump taken under an active writer is still consistent, but the
# recovered row count would then be un-assertable: rows added between the dump
# and the count would look like restore loss.
k scale "deployment/${EDGE_DEPLOYMENT}" --replicas=0 >/dev/null
edge_gone() { [ -z "$(component_pod edge)" ]; }
retry_until "the capture daemon to stop" "$SHORT_POLL_ATTEMPTS" "$POLL_DELAY_SECONDS" edge_gone \
    || fail "the edge pod did not stop; the dump would not be a stable restore point"

k create job "$RESTORE_JOB" --from="cronjob/${CRONJOB_NAME}"
k wait --for=condition=complete "job/${RESTORE_JOB}" --timeout "$JOB_COMPLETION_TIMEOUT" \
    || { k logs "job/${RESTORE_JOB}" --container dump >&2 || true
         fail "the scheduled backup Job did not complete, so there is no artifact to restore from"; }
k logs "job/${RESTORE_JOB}" --container dump >"${SCRATCH_DIRECTORY}/backup-job.log"
assert_no_credential_leak "${SCRATCH_DIRECTORY}/backup-job.log"

ARTIFACT="$(workbench_sh '
    find "$INDIALLSKY_BACKUP_DIR" -maxdepth 1 -type f -name "$1*.sql.gz" -printf "%T@ %p\n" \
        | sort -rn | head -1 | cut -d" " -f2-
' "$SCHEDULED_DUMP_PREFIX" | tr -d '\r\n')"
test -n "$ARTIFACT" || fail "the completed backup Job left no ${SCHEDULED_DUMP_PREFIX}_*.sql.gz artifact"
note "recovery artifact: ${ARTIFACT}"

image_rows_at_dump="$(db_row_count image)"
user_rows_at_dump="$(db_row_count user)"
witness_filename="$(db_query 'SELECT filename FROM image ORDER BY id DESC LIMIT 1;' | tr -d '\r')"
revision_at_dump="$(db_query 'SELECT version_num FROM alembic_version;' | tr -d '[:space:]')"
admin_username="$(k get configmap "$(env_configmap_name)" --output jsonpath='{.data.INDIALLSKY_WEB_USER}')"
note "restore point: ${image_rows_at_dump} image rows, ${user_rows_at_dump} accounts, revision ${revision_at_dump}"


# --- the documented recovery-set preflight ------------------------------------

# The documented recovery set is more than the SQL dump. This preflight is the
# executable form of that list, and it is what the failure scenarios below are
# run against. It prints one line per item and refuses on the first item it
# cannot account for, naming the item — never a credential, which it does not
# have.
recovery_preflight() {  # $1 = artifact path inside the workbench
    workbench_sh '
        artifact="$1"
        printf "recovery-set preflight for %s\n" "$artifact"

        if [ ! -f "$artifact" ]; then
            printf "REFUSED: the logical dump %s is not a regular file\n" "$artifact" >&2
            exit 1
        fi
        if [ ! -s "$artifact" ]; then
            printf "REFUSED: the logical dump %s is empty\n" "$artifact" >&2
            exit 1
        fi
        if ! gzip -t "$artifact" 2>/dev/null; then
            printf "REFUSED: the logical dump %s does not pass gzip -t; it is truncated or corrupt and must not be salvaged\n" "$artifact" >&2
            exit 1
        fi
        printf "  gzip stream verified (%s bytes compressed)\n" "$(stat -c %s "$artifact")"

        if [ ! -f "$INDIALLSKY_MIGRATION_FOLDER/env.py" ]; then
            printf "REFUSED: the Alembic migration history is missing from %s; restoring the dump alone would leave the schema history unrecoverable\n" "$INDIALLSKY_MIGRATION_FOLDER" >&2
            exit 1
        fi
        printf "  migration history present (%s revisions)\n" \
            "$(find "$INDIALLSKY_MIGRATION_FOLDER/versions" -maxdepth 1 -type f -name "*.py" | wc -l)"

        if [ -z "$(find "$INDIALLSKY_IMAGE_FOLDER" -type f -name "*.jpg" -print -quit)" ]; then
            printf "REFUSED: no image files were found under %s; the catalogue would reference files that do not exist\n" "$INDIALLSKY_IMAGE_FOLDER" >&2
            exit 1
        fi
        printf "  image archive present\n"
        printf "recovery set complete\n"
    ' "$1"
}

section "Recovery-set preflight on a complete set"

preflight_log="${SCRATCH_DIRECTORY}/preflight-complete.log"
recovery_preflight "$ARTIFACT" >"$preflight_log" 2>&1 \
    || { cat "$preflight_log" >&2; fail "the preflight refused a complete recovery set"; }
cat "$preflight_log"

# The application Secret is the part of the recovery set Helm holds rather than
# the volume: without the Fernet password key the configuration's encrypted
# fields are unreadable even from a perfect dump.
for key in INDIALLSKY_FLASK_SECRET_KEY INDIALLSKY_FLASK_PASSWORD_KEY MARIADB_PASSWORD; do
    test -n "$(secret_value "$APP_SECRET" "$key")" \
        || fail "the application Secret ${APP_SECRET} has no ${key}; it is part of the recovery set"
done
test -n "$(secret_value "$ROOT_SECRET" MARIADB_ROOT_PASSWORD)" \
    || fail "the preserved root recovery credential is missing from ${ROOT_SECRET}"
assert_no_credential_leak "$preflight_log"
pass "the complete recovery set passes preflight: dump, migration history, image archive, application Secret, root credential"


# --- failure diagnostics ------------------------------------------------------

section "Failure diagnostics: a corrupt gzip stream"

corrupt_artifact="${ARTIFACT%.sql.gz}.corrupt.sql.gz"
workbench_sh '
    # A truncated copy: the header is intact so the file still looks like a
    # dump, which is exactly the artifact an operator is tempted to salvage.
    head -c 2048 "$1" > "$2"
    chmod 0600 "$2"
' "$ARTIFACT" "$corrupt_artifact"

corrupt_log="${SCRATCH_DIRECTORY}/preflight-corrupt.log"
corrupt_status=0
recovery_preflight "$corrupt_artifact" >"$corrupt_log" 2>&1 || corrupt_status=$?
test "$corrupt_status" -ne 0 || { cat "$corrupt_log" >&2; fail "the preflight accepted a truncated dump"; }
grep -Fq 'does not pass gzip -t' "$corrupt_log" \
    || { cat "$corrupt_log" >&2; fail "the corrupt-dump diagnostic did not name gzip verification as the reason"; }
grep -Fq "$corrupt_artifact" "$corrupt_log" \
    || fail "the corrupt-dump diagnostic did not name the offending artifact"
assert_no_credential_leak "$corrupt_log"
workbench_sh 'rm -f -- "$1"' "$corrupt_artifact"
pass "a truncated dump is refused with an actionable diagnostic and no credential value"

section "Failure diagnostics: an incomplete recovery set"

# The dump is fine; the migration history is not present. Restoring anyway
# would produce a database whose schema history nothing can extend.
workbench_sh 'mv -- "$INDIALLSKY_MIGRATION_FOLDER" "${INDIALLSKY_MIGRATION_FOLDER}$1"' "$HIDDEN_MIGRATION_SUFFIX"
incomplete_log="${SCRATCH_DIRECTORY}/preflight-incomplete.log"
incomplete_status=0
recovery_preflight "$ARTIFACT" >"$incomplete_log" 2>&1 || incomplete_status=$?
workbench_sh 'mv -- "${INDIALLSKY_MIGRATION_FOLDER}$1" "$INDIALLSKY_MIGRATION_FOLDER"' "$HIDDEN_MIGRATION_SUFFIX"

test "$incomplete_status" -ne 0 \
    || { cat "$incomplete_log" >&2; fail "the preflight accepted a recovery set with no migration history"; }
grep -Fq 'Alembic migration history is missing' "$incomplete_log" \
    || { cat "$incomplete_log" >&2; fail "the incomplete-set diagnostic did not name the missing migration history"; }
assert_no_credential_leak "$incomplete_log"
recovery_preflight "$ARTIFACT" >/dev/null 2>&1 \
    || fail "the recovery set did not pass preflight again after the migration history was put back"
pass "an incomplete recovery set is refused by name, and the set passes again once it is whole"


# --- the restore --------------------------------------------------------------

section "Destroy and restore"

k patch cronjob "$CRONJOB_NAME" --type merge --patch '{"spec":{"suspend":true}}' >/dev/null
k scale "deployment/${WEB_DEPLOYMENT}" --replicas=0 >/dev/null
web_gone() { [ -z "$(component_pod web)" ]; }
retry_until "the web pod to stop" "$SHORT_POLL_ATTEMPTS" "$POLL_DELAY_SECONDS" web_gone \
    || fail "the web pod did not stop; the restore would race a live migration"
pass "writers quiesced: capture stopped, web stopped, scheduled backups suspended"

database_name="$(k get configmap "$(env_configmap_name)" --output jsonpath='{.data.MARIADB_DATABASE}')"
database_user="$(k get configmap "$(env_configmap_name)" --output jsonpath='{.data.MARIADB_USER}')"

# A real loss, not a truncate: DROP DATABASE also removes the schema-level
# grants, which is why re-granting is part of the documented procedure rather
# than an afterthought.
db_root_query "DROP DATABASE IF EXISTS \`${database_name}\`;" >/dev/null
db_root_query "CREATE DATABASE \`${database_name}\` CHARACTER SET ${TARGET_CHARSET} COLLATE ${TARGET_COLLATION};" >/dev/null

# Before the grant the application account must NOT be able to use the target.
# Asserting that makes the grant step a demonstrated requirement rather than a
# line of prose that might be superfluous.
if db_query 'SELECT 1;' >/dev/null 2>&1; then
    fail "the application account could still use ${database_name} before its grants were restored; the prepare-target step is not being exercised"
fi
db_root_query "GRANT ALL PRIVILEGES ON \`${database_name}\`.* TO '${database_user}'@'%'; FLUSH PRIVILEGES;" >/dev/null
db_query 'SELECT 1;' >/dev/null \
    || fail "the application account still cannot use ${database_name} after the grant was restored"
pass "target schema recreated with ${TARGET_CHARSET}/${TARGET_COLLATION} and the application grants restored"

restore_log="${SCRATCH_DIRECTORY}/restore.log"
workbench_sh '
    artifact="$1"
    gzip -t "$artifact"
    # MYSQL_PWD, never -p: the password must stay out of the container argv.
    export MYSQL_PWD="$MARIADB_PASSWORD"
    gzip -cd "$artifact" \
        | mariadb --host="$INDIALLSKY_MARIADB_HOST" --port="$INDIALLSKY_MARIADB_PORT" \
                  --user="$MARIADB_USER" "$MARIADB_DATABASE"
    printf "restored %s\n" "$artifact"
' "$ARTIFACT" >"$restore_log" 2>&1 \
    || { cat "$restore_log" >&2; fail "restoring the verified dump failed"; }
assert_no_credential_leak "$restore_log"
pass "the verified dump was restored into the prepared schema"


# --- bring the workloads back -------------------------------------------------

section "Restart with the matching application Secret"

k scale "deployment/${WEB_DEPLOYMENT}" --replicas=1 >/dev/null
k rollout status "deployment/${WEB_DEPLOYMENT}" --timeout "$WORKLOAD_ROLLOUT_TIMEOUT" \
    || { k logs "$(component_pod web)" --container migrate >&2 2>/dev/null || true
         fail "the web Deployment did not come back after the restore"; }
k scale "deployment/${EDGE_DEPLOYMENT}" --replicas=1 >/dev/null
k rollout status "deployment/${EDGE_DEPLOYMENT}" --timeout "$WORKLOAD_ROLLOUT_TIMEOUT" \
    || fail "the edge Deployment did not come back after the restore"
k patch cronjob "$CRONJOB_NAME" --type merge --patch '{"spec":{"suspend":false}}' >/dev/null

# A complete, consistent restore leaves nothing for the migration path to do.
# If this run had found pending work it would mean the restored schema and the
# preserved migration history disagreed.
post_restore_migrate_log="${SCRATCH_DIRECTORY}/post-restore-migrate.log"
k logs "$(component_pod web)" --container migrate >"$post_restore_migrate_log"
grep -Fq 'Schema matches models and committed revisions; no pre-migration dump needed' "$post_restore_migrate_log" \
    || { cat "$post_restore_migrate_log" >&2
         fail "after the restore the migration path found pending schema work; the restored database and the preserved migration history disagree"; }
assert_no_credential_leak "$post_restore_migrate_log"
pass "the restored schema and the preserved migration history agree; no migration work was pending"


# --- prove the application reads what was restored ----------------------------

section "The application reads the restored configuration and catalogue"

revision_after="$(db_query 'SELECT version_num FROM alembic_version;' | tr -d '[:space:]')"
test "$revision_after" = "$revision_at_dump" \
    || fail "the restored alembic revision is ${revision_after}, not the ${revision_at_dump} the dump was taken at"

restored_witness="$(db_query "SELECT COUNT(*) FROM image WHERE filename = '${witness_filename}';" | tr -d '[:space:]')"
test "$restored_witness" -eq 1 \
    || fail "the image row recorded before the dump (${witness_filename}) did not come back"
image_rows_after="$(db_row_count image)"
test "$image_rows_after" -ge "$image_rows_at_dump" \
    || fail "the restored catalogue holds ${image_rows_after} rows, fewer than the ${image_rows_at_dump} present when the dump was taken"

if [ -n "$admin_username" ]; then
    restored_admin="$(db_query "SELECT COUNT(*) FROM \`user\` WHERE username = '${admin_username}';" | tr -d '[:space:]')"
    test "$restored_admin" -eq 1 \
        || fail "the seeded admin account did not survive the restore"
fi

# The decisive configuration assertion. `config.py dumpfile` decrypts the
# configuration's credential fields with INDIALLSKY_FLASK_PASSWORD_KEY, so it
# succeeds only when the restored rows and the PRESERVED application Secret are
# the matching pair. Output goes to /dev/null because a configuration dump
# contains decrypted third-party credentials.
config_log="${SCRATCH_DIRECTORY}/config-read.log"
k exec "$(component_pod web)" --container gunicorn -- bash -c '
    set -Eeuo pipefail
    cd /home/allsky/indi-allsky
    # shellcheck disable=SC1091
    source /home/allsky/venv/bin/activate
    ./config.py dumpfile -o /dev/null >/dev/null
    printf "configuration decrypted and read\n"
' >"$config_log" 2>&1 \
    || { cat "$config_log" >&2
         fail "the application could not read the restored configuration; the dump and the application Secret are not a matching recovery set"; }
assert_no_credential_leak "$config_log"
pass "the application decrypted and read the restored configuration with the preserved Secret"

service_name="$(web_service_name)"
k port-forward "service/${service_name}" "${LOCAL_FORWARD_PORT}:${NGINX_PORT}" >"${SCRATCH_DIRECTORY}/port-forward.log" 2>&1 &
FORWARD_PID=$!
sleep "$PORT_FORWARD_SETTLE_SECONDS"

camera_id="$(db_query 'SELECT id FROM camera ORDER BY id DESC LIMIT 1;' | tr -d '[:space:]')"
test -n "$camera_id" || fail "the restored database has no camera row"
latest_json="${SCRATCH_DIRECTORY}/latest.json"
curl --silent --show-error --fail --max-time "$CURL_MAX_TIME_SECONDS" --output "$latest_json" \
    "http://127.0.0.1:${LOCAL_FORWARD_PORT}/indi-allsky/js/latest?camera_id=${camera_id}&limit_s=${LATEST_HISTORY_SECONDS}" \
    || fail "the application did not serve js/latest after the restore"
jq -e '.latest_image.url != null' "$latest_json" >/dev/null \
    || { cat "$latest_json" >&2; fail "after the restore the application cannot see a catalogued frame"; }
pass "the web Service serves the restored catalogue's latest image"

assert_root_secret_isolated
pass "the root Secret is still confined to the database pod after the whole procedure"

printf '\nrestore: artifact=verified target=recreated+regranted rowsRecovered=%s configReadable=yes revision=%s rootIsolation=held\n' \
    "$image_rows_at_dump" "$revision_after"
