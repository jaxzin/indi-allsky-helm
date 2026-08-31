#!/usr/bin/env bash
# The shared database-maintenance advisory lock, exercised IN-CLUSTER in both
# start orders.
#
# charts/indi-allsky/tests/db-maintenance-behavior.sh already proves the
# supervisor's behaviour against a throwaway MariaDB: it serializes, it logs
# progress, it releases on signals, and it propagates statuses. This scenario
# proves a different and harder thing — that the two workloads the chart
# actually ships take the same lock, across pods, through the cluster's DNS and
# NetworkPolicy, on a database reached by Service rather than by container name.
# A lock that worked in a docker network and silently took two different locks
# in Kubernetes would pass that bench and fail here.
#
# In each order the LOSING actor is the real thing, because the loser is what
# the safety property is about:
#
#   * migration-first  — a stand-in holds the lock; the REAL scheduled backup
#                        Job, created from the chart's own CronJob, must wait
#                        and must publish nothing while it waits.
#   * backup-first     — a stand-in holds the lock across a real
#                        scheduled-backup.sh run; the REAL web migration
#                        initContainer must wait and must reach neither its
#                        pre-migration dump nor any DDL while it waits.
#
# The stand-in winner is a `db-maintenance-lock.sh -- sleep` inside the
# workbench pod. The lock is role-agnostic — a MariaDB named lock has no idea
# which workload took it — so what a stand-in cannot represent is only the
# winner's own work, and the winner's own work is not what is being asserted.
#
# Single-quoted in-pod command strings are expanded in the pod, not here.
# shellcheck disable=SC2016  # in-pod strings are expanded in the pod
set -Eeuo pipefail

SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=e2e/lib.sh
# shellcheck disable=SC1091  # resolved only when shellcheck is run with -x over the whole directory
source "${SCRIPT_DIRECTORY}/lib.sh"

SCHEDULED_DUMP_PREFIX="indi-allsky_scheduled"
PRE_MIGRATE_DUMP_PREFIX="pre-migrate"

# The supervisor logs "Still waiting…" after 30 seconds of contention, so a
# hold has to outlast that plus the time it takes the loser to start. 90s
# clears both with margin on a busy runner.
LOCK_HOLD_SECONDS=90
HOLD_ACQUIRE_ATTEMPTS=24
CONTENTION_OBSERVED_ATTEMPTS=36
JOB_COMPLETION_TIMEOUT="600s"
WEB_ROLLOUT_TIMEOUT="900s"

MIGRATION_HOLDER_LOG="/tmp/e2e-holder-migration.log"
BACKUP_HOLDER_LOG="/tmp/e2e-holder-backup.log"
BACKUP_HOLDER_SCRIPT="/tmp/e2e-holder-backup.sh"
# A column the models do not declare, so `flask db check` reports a genuine
# difference and the migration path has real work — and therefore a real
# pre-migration dump to publish — to be held back from.
DRIFT_COLUMN="e2e_lock_drift"

ORDER_ONE_JOB="e2e-backup-order-one"
SCRATCH_DIRECTORY="$(mktemp -d)"

cleanup() {
    k delete job "$ORDER_ONE_JOB" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    rm -rf -- "$SCRATCH_DIRECTORY"
}
trap cleanup EXIT INT TERM HUP

workbench_apply
CRONJOB_NAME="$(backup_cronjob)"
test -n "$CRONJOB_NAME" || fail "the release renders no backup CronJob; mariadb.backup.enabled must be true for this scenario"


# --- lock holders ------------------------------------------------------------

# Detached inside the workbench: `kubectl exec` ends when its command exits, so
# the holder is nohup'd and its output goes to a file in the pod rather than
# down the exec stream.
holder_start() {  # $1 = in-pod log path, $2.. = the protected command
    local log="$1"
    shift
    workbench_sh '
        log="$1"
        shift
        rm -f -- "$log"
        nohup /home/allsky/db-maintenance-lock.sh -- "$@" >"$log" 2>&1 &
        printf "holder started\n"
    ' "$log" "$@" >/dev/null
}

holder_log() {  # $1 = in-pod log path
    workbench_sh 'cat -- "$1" 2>/dev/null || true' "$1"
}

holder_holds() {  # $1 = in-pod log path
    holder_log "$1" | grep -Fq 'Holding the database maintenance advisory lock'
}

holder_released() {  # $1 = in-pod log path
    holder_log "$1" | grep -Fq 'Released the database maintenance advisory lock'
}


# --- order one: a migration holds, the real backup Job waits ------------------

section "Order one — migration holds the lock, the scheduled backup Job loses"

scheduled_before="$(backup_artifact_count "$SCHEDULED_DUMP_PREFIX")"

holder_start "$MIGRATION_HOLDER_LOG" sleep "$LOCK_HOLD_SECONDS"
holds_migration() { holder_holds "$MIGRATION_HOLDER_LOG"; }
retry_until "the stand-in migration holder to acquire the lock" \
    "$HOLD_ACQUIRE_ATTEMPTS" "$POLL_DELAY_SECONDS" holds_migration \
    || fail "the stand-in migration holder never acquired the advisory lock"
note "stand-in migration holder is inside its critical section for ${LOCK_HOLD_SECONDS}s"

k create job "$ORDER_ONE_JOB" --from="cronjob/${CRONJOB_NAME}"

order_one_log="${SCRATCH_DIRECTORY}/order-one-backup.log"
backup_is_waiting() {
    k logs "job/${ORDER_ONE_JOB}" --container dump >"$order_one_log" 2>/dev/null || return 1
    grep -Fq 'Still waiting for database maintenance advisory lock' "$order_one_log"
}
retry_until "the scheduled backup Job to report that it is waiting for the lock" \
    "$CONTENTION_OBSERVED_ATTEMPTS" "$POLL_DELAY_SECONDS" backup_is_waiting \
    || {
        k describe job "$ORDER_ONE_JOB" >&2 || true
        fail "the scheduled backup Job never reported waiting behind the migration's lock"
    }

# The decisive assertion: while the winner still holds, the loser has published
# nothing. A dump appearing here would mean the lock did not actually serialize
# the two workloads.
holder_holds "$MIGRATION_HOLDER_LOG" \
    || fail "the stand-in holder never reported holding, so the count below would prove nothing"
if holder_released "$MIGRATION_HOLDER_LOG"; then
    fail "the stand-in holder had already released the lock, so the count below would prove nothing"
fi
scheduled_during="$(backup_artifact_count "$SCHEDULED_DUMP_PREFIX")"
test "$scheduled_during" -eq "$scheduled_before" \
    || fail "the scheduled backup published an artifact ($scheduled_before -> $scheduled_during) while a migration held the maintenance lock"
pass "the scheduled backup waited and published nothing while the lock was held"

k wait --for=condition=complete "job/${ORDER_ONE_JOB}" --timeout "$JOB_COMPLETION_TIMEOUT" \
    || {
        k logs "job/${ORDER_ONE_JOB}" --container dump >&2 || true
        fail "the scheduled backup Job did not complete after the lock was released"
    }
k logs "job/${ORDER_ONE_JOB}" --container dump >"$order_one_log"

scheduled_after="$(backup_artifact_count "$SCHEDULED_DUMP_PREFIX")"
test "$scheduled_after" -eq $((scheduled_before + 1)) \
    || fail "after the lock was released the scheduled backup produced ${scheduled_after} artifacts, expected $((scheduled_before + 1))"

waiting_line="$(grep -n 'Still waiting for database maintenance advisory lock' "$order_one_log" | head -1 | cut -d: -f1)"
published_line="$(grep -n 'Verified database dump published' "$order_one_log" | head -1 | cut -d: -f1)"
test -n "$published_line" || fail "the scheduled backup Job never reported publishing a verified dump"
test "$waiting_line" -lt "$published_line" \
    || fail "the scheduled backup published before it reported waiting, so it did not wait for the lock"
assert_no_credential_leak "$order_one_log"
pass "the scheduled backup retried after release and published exactly one verified dump, leaking no credential"


# --- order two: a backup holds, the real migration waits ----------------------

section "Order two — the scheduled backup holds the lock, the web migration loses"

# Real schema work, so the migration has a pre-migration dump to publish and
# real DDL to run. Without this the "it published nothing while blocked"
# assertion below would be satisfied by a migration that had nothing to do.
db_query "ALTER TABLE image ADD COLUMN \`${DRIFT_COLUMN}\` TINYINT NULL;" >/dev/null
note "introduced a schema difference (image.${DRIFT_COLUMN}) so the migration has work to be held back from"

pre_migrate_before="$(backup_artifact_count "$PRE_MIGRATE_DUMP_PREFIX")"

workbench_sh '
    printf "%s\n" "/home/allsky/scheduled-backup.sh" "sleep $1" > "$2"
    chmod 0700 "$2"
' "$LOCK_HOLD_SECONDS" "$BACKUP_HOLDER_SCRIPT"
holder_start "$BACKUP_HOLDER_LOG" /bin/bash "$BACKUP_HOLDER_SCRIPT"

backup_holder_published() {
    holder_log "$BACKUP_HOLDER_LOG" | grep -Fq 'Verified database dump published'
}
retry_until "the backup holder to publish inside its critical section" \
    "$HOLD_ACQUIRE_ATTEMPTS" "$POLL_DELAY_SECONDS" backup_holder_published \
    || fail "the backup holder never completed a dump inside the lock"
note "backup holder is inside its critical section for a further ${LOCK_HOLD_SECONDS}s"

WEB_DEPLOYMENT="$(web_deployment)"

# Scaled to zero and back rather than deleted: a deleted pod leaves a
# terminating predecessor alongside its replacement for a while, and reading
# "the web pod's migrate log" during that window can return the PREVIOUS pod's
# completed migration — which would make every assertion below pass for the
# wrong reason.
web_pod_gone() { [ -z "$(component_pod web)" ]; }
web_pod_exists() { [ -n "$(component_pod web)" ]; }
k scale "deployment/${WEB_DEPLOYMENT}" --replicas=0 >/dev/null
retry_until "the web pod to terminate" "$SHORT_POLL_ATTEMPTS" "$POLL_DELAY_SECONDS" web_pod_gone \
    || fail "the web pod did not terminate after scaling to zero"
k scale "deployment/${WEB_DEPLOYMENT}" --replicas=1 >/dev/null
retry_until "a replacement web pod to appear" "$SHORT_POLL_ATTEMPTS" "$POLL_DELAY_SECONDS" web_pod_exists \
    || fail "no replacement web pod appeared after scaling back to one"
web_pod="$(component_pod web)"

migrate_log="${SCRATCH_DIRECTORY}/order-two-migrate.log"
migrate_is_waiting() {
    k logs "$web_pod" --container migrate >"$migrate_log" 2>/dev/null || return 1
    grep -Fq 'Still waiting for database maintenance advisory lock' "$migrate_log"
}
retry_until "the web migration initContainer to report waiting for the lock" \
    "$CONTENTION_OBSERVED_ATTEMPTS" "$POLL_DELAY_SECONDS" migrate_is_waiting \
    || {
        k describe pod "$web_pod" >&2 || true
        fail "the web migration never reported waiting behind the scheduled backup's lock"
    }

# The losing migration must be outside its critical section entirely: no lock
# acquisition, no dump, no schema statement.
if grep -Fq 'Holding the database maintenance advisory lock' "$migrate_log"; then
    fail "the web migration reported holding the lock while the scheduled backup still held it"
fi
if grep -Fq 'Verified database dump published' "$migrate_log"; then
    fail "the web migration published its pre-migration dump before acquiring the lock"
fi
if grep -Eq 'Running upgrade|Model changes detected' "$migrate_log"; then
    fail "the web migration ran schema work before acquiring the lock"
fi
pre_migrate_during="$(backup_artifact_count "$PRE_MIGRATE_DUMP_PREFIX")"
test "$pre_migrate_during" -eq "$pre_migrate_before" \
    || fail "a pre-migration dump appeared ($pre_migrate_before -> $pre_migrate_during) while the scheduled backup held the maintenance lock"
pass "the blocked migration entered neither its dump publication nor any DDL"

k rollout status "deployment/${WEB_DEPLOYMENT}" --timeout "$WEB_ROLLOUT_TIMEOUT" \
    || fail "the web Deployment did not become available after the lock was released"
k logs "$web_pod" --container migrate >"$migrate_log"

pre_migrate_after="$(backup_artifact_count "$PRE_MIGRATE_DUMP_PREFIX")"
test "$pre_migrate_after" -eq $((pre_migrate_before + 1)) \
    || fail "after acquiring the lock the migration published ${pre_migrate_after} pre-migration dumps, expected $((pre_migrate_before + 1))"

waiting_line="$(grep -n 'Still waiting for database maintenance advisory lock' "$migrate_log" | head -1 | cut -d: -f1)"
holding_line="$(grep -n 'Holding the database maintenance advisory lock' "$migrate_log" | head -1 | cut -d: -f1)"
dump_line="$(grep -n 'Verified database dump published' "$migrate_log" | head -1 | cut -d: -f1)"
test -n "$holding_line" || fail "the migration never reported acquiring the lock"
test "$waiting_line" -lt "$holding_line" || fail "the migration's acquisition was logged before its wait"
test "$holding_line" -lt "$dump_line" || fail "the migration published its dump before it held the lock"
grep -Fq 'Migration and bootstrap complete' "$migrate_log" \
    || fail "the migration did not complete after retrying behind the released lock"
assert_no_credential_leak "$migrate_log"
pass "the migration retried after release, dumped inside the lock, and completed"

# The drift column was the fixture for this scenario; the guarded autogenerate
# path removed it, which is asserted in its own right by
# e2e/verify-migration-paths.sh.
drift_remaining="$(db_query "SELECT COUNT(*) FROM information_schema.columns WHERE table_schema = DATABASE() AND table_name = 'image' AND column_name = '${DRIFT_COLUMN}';" | tr -d '[:space:]')"
note "image.${DRIFT_COLUMN} columns remaining after the guarded migration: ${drift_remaining}"

printf '\ndatabase maintenance: bothOrders=serialized loserPublishedWhileBlocked=0 retryAfterRelease=ok credentialLeak=no\n'
