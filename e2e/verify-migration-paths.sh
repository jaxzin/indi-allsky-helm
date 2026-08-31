#!/usr/bin/env bash
# The three migration paths issue #29 asks A9 to cover end to end, in the order
# that lets each one start from a known schema state.
#
#   A. Guarded runtime autogenerate. A genuine model/schema difference is
#      introduced, and the migration must publish a verified dump BEFORE any
#      statement that could change the schema, then autogenerate and apply a
#      revision.
#   B. The INDIALLSKY_PRE_MIGRATE_DUMP=false escape hatch. The strict true|false
#      parse is unit-covered; what is not is that setting migrations.
#      preMigrateDump=false in the chart reaches the script and really does
#      skip the dump while still doing the schema work.
#   C. An upgrade against an already-committed revision. This is the case the
#      safety property was changed for: before, `flask db upgrade head` could
#      apply a committed revision — real DDL — with no recovery artifact behind
#      it, because only the autogenerate branch dumped. The pre-seeded revision
#      here creates a VIEW, which SQLAlchemy's table reflection does not report,
#      so `flask db check` stays clean afterwards and the assertion is
#      unambiguously "upgrade applied it", not "autogenerate rewrote it".
#
# Single-quoted in-pod command strings are expanded in the pod, not here.
# shellcheck disable=SC2016  # in-pod strings are expanded in the pod
set -Eeuo pipefail

SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=e2e/lib.sh
# shellcheck disable=SC1091  # resolved only when shellcheck is run with -x over the whole directory
source "${SCRIPT_DIRECTORY}/lib.sh"

PRE_MIGRATE_DUMP_PREFIX="pre-migrate"
WEB_ROLLOUT_TIMEOUT="900s"

AUTOGENERATE_DRIFT_COLUMN="e2e_autogenerate_drift"
ESCAPE_HATCH_DRIFT_COLUMN="e2e_escape_hatch_drift"

# Alembic's version_num column is VARCHAR(32); this is a deliberately
# recognisable id so a failure names the fixture rather than a random hash.
SEEDED_REVISION_ID="e2eseededrevision"
SEEDED_REVISION_VIEW="e2e_existing_revision_probe"
SEEDED_REVISION_MESSAGE="e2e pre-seeded committed revision"

SCRATCH_DIRECTORY="$(mktemp -d)"
cleanup() {
    rm -rf -- "$SCRATCH_DIRECTORY"
}
trap cleanup EXIT INT TERM HUP

workbench_apply
WEB_DEPLOYMENT="$(web_deployment)"


# --- helpers -----------------------------------------------------------------

web_pod_gone() { [ -z "$(component_pod web)" ]; }
web_pod_exists() { [ -n "$(component_pod web)" ]; }

# Scale to zero and back, then hand back the NEW pod's migrate log. Scaling
# rather than deleting keeps a terminating predecessor from being mistaken for
# the pod under test.
restart_web_capturing_migrate_log() {  # $1 = destination file
    k scale "deployment/${WEB_DEPLOYMENT}" --replicas=0 >/dev/null
    retry_until "the web pod to terminate" "$SHORT_POLL_ATTEMPTS" "$POLL_DELAY_SECONDS" web_pod_gone \
        || fail "the web pod did not terminate after scaling to zero"
    k scale "deployment/${WEB_DEPLOYMENT}" --replicas=1 >/dev/null
    retry_until "a replacement web pod to appear" "$SHORT_POLL_ATTEMPTS" "$POLL_DELAY_SECONDS" web_pod_exists \
        || fail "no replacement web pod appeared after scaling back to one"
    k rollout status "deployment/${WEB_DEPLOYMENT}" --timeout "$WEB_ROLLOUT_TIMEOUT" \
        || { k logs "$(component_pod web)" --container migrate >&2 2>/dev/null || true
             fail "the web Deployment did not become available after the restart"; }
    k logs "$(component_pod web)" --container migrate >"$1"
}

# A values change rolls the pod through the Deployment's env-ConfigMap checksum
# annotation, so the new pod is identified by "not the one that was there
# before" rather than by racing the rollout.
upgrade_web_capturing_migrate_log() {  # $1 = destination file, $2.. = helm arguments
    local destination="$1" previous_pod
    shift
    previous_pod="$(component_pod web)"
    "${SCRIPT_DIRECTORY}/install-release.sh" "$@"
    replaced() {
        local current
        current="$(component_pod web)"
        [ -n "$current" ] && [ "$current" != "$previous_pod" ]
    }
    retry_until "the values change to roll the web pod" \
        "$SHORT_POLL_ATTEMPTS" "$POLL_DELAY_SECONDS" replaced \
        || fail "the web pod was not replaced after the values change; the env ConfigMap checksum annotation should have rolled it"
    k rollout status "deployment/${WEB_DEPLOYMENT}" --timeout "$WEB_ROLLOUT_TIMEOUT" \
        || { k logs "$(component_pod web)" --container migrate >&2 2>/dev/null || true
             fail "the web Deployment did not become available after the values change"; }
    k logs "$(component_pod web)" --container migrate >"$destination"
}

column_exists() {  # $1 = table, $2 = column
    local count
    count="$(db_query "SELECT COUNT(*) FROM information_schema.columns WHERE table_schema = DATABASE() AND table_name = '$1' AND column_name = '$2';" | tr -d '[:space:]')"
    [ "${count:-0}" -gt 0 ]
}

# Line number of the first match, or the empty string. The `|| true` is
# load-bearing: under pipefail a non-matching grep fails the whole pipeline, and
# inside a command substitution that ends the script with no diagnostic at all.
# require_order below is what turns "no match" into an actionable message.
line_of() {  # $1 = pattern (extended regex), $2 = file -> line number or empty
    grep -n -E -- "$1" "$2" | head -1 | cut -d: -f1 || true
}

require_order() {  # $1 = file, $2 = earlier regex, $3 = later regex, $4 = description
    local earlier later
    earlier="$(line_of "$2" "$1")"
    later="$(line_of "$3" "$1")"
    test -n "$earlier" || fail "${4}: the migration log never matched /${2}/"
    test -n "$later" || fail "${4}: the migration log never matched /${3}/"
    test "$earlier" -lt "$later" \
        || fail "${4}: /${2}/ appeared at line ${earlier}, after /${3}/ at line ${later}"
}

revision_file_count() {
    workbench_sh 'find "$1/versions" -maxdepth 1 -type f -name "*.py" | wc -l' "$MIGRATION_PATH" \
        | tr -d '[:space:]'
}


# --- A. guarded runtime autogenerate -----------------------------------------

section "A — a genuine model/schema difference is dumped before it is migrated"

dumps_before="$(backup_artifact_count "$PRE_MIGRATE_DUMP_PREFIX")"
revisions_before="$(revision_file_count)"
db_query "ALTER TABLE image ADD COLUMN \`${AUTOGENERATE_DRIFT_COLUMN}\` TINYINT NULL;" >/dev/null
column_exists image "$AUTOGENERATE_DRIFT_COLUMN" \
    || fail "the drift column was not created, so this scenario would prove nothing"

autogenerate_log="${SCRATCH_DIRECTORY}/autogenerate.log"
restart_web_capturing_migrate_log "$autogenerate_log"

grep -Fq 'Schema work is pending' "$autogenerate_log" \
    || fail "the migration did not detect the introduced schema difference as pending work"
require_order "$autogenerate_log" 'Verified database dump published' 'Model changes detected' \
    "the guarded autogenerate path"
grep -Fq 'Model changes detected; generating guarded migration' "$autogenerate_log" \
    || fail "the migration did not take the guarded autogenerate branch for a real model difference"

dumps_after="$(backup_artifact_count "$PRE_MIGRATE_DUMP_PREFIX")"
test "$dumps_after" -eq $((dumps_before + 1)) \
    || fail "the guarded path published ${dumps_after} dumps, expected $((dumps_before + 1))"
revisions_after="$(revision_file_count)"
test "$revisions_after" -eq $((revisions_before + 1)) \
    || fail "autogenerate wrote ${revisions_after} revision files, expected $((revisions_before + 1))"
if column_exists image "$AUTOGENERATE_DRIFT_COLUMN"; then
    fail "the autogenerated revision did not remove the drift column, so the schema was not actually reconciled"
fi
assert_no_credential_leak "$autogenerate_log"
pass "the difference was dumped first, then autogenerated and applied; one new dump, one new revision"


# --- B. the escape hatch ------------------------------------------------------

section "B — INDIALLSKY_PRE_MIGRATE_DUMP=false skips the dump and nothing else"

dumps_before="$(backup_artifact_count "$PRE_MIGRATE_DUMP_PREFIX")"
db_query "ALTER TABLE image ADD COLUMN \`${ESCAPE_HATCH_DRIFT_COLUMN}\` TINYINT NULL;" >/dev/null
column_exists image "$ESCAPE_HATCH_DRIFT_COLUMN" \
    || fail "the drift column was not created, so the skipped dump would be unremarkable"

escape_hatch_log="${SCRATCH_DIRECTORY}/escape-hatch.log"
upgrade_web_capturing_migrate_log "$escape_hatch_log" --set migrations.preMigrateDump=false

rendered_value="$(k get configmap "$(env_configmap_name)" \
    --output jsonpath='{.data.INDIALLSKY_PRE_MIGRATE_DUMP}')"
test "$rendered_value" = "false" \
    || fail "migrations.preMigrateDump=false rendered INDIALLSKY_PRE_MIGRATE_DUMP=${rendered_value}"

grep -Fq 'Schema work is pending' "$escape_hatch_log" \
    || fail "the escape-hatch run found no pending schema work, so skipping the dump proves nothing"
grep -Fq 'INDIALLSKY_PRE_MIGRATE_DUMP=false; proceeding without a pre-migration dump' "$escape_hatch_log" \
    || fail "the migration did not report taking the escape hatch"
if grep -Fq 'Verified database dump published' "$escape_hatch_log"; then
    fail "the migration published a pre-migration dump despite INDIALLSKY_PRE_MIGRATE_DUMP=false"
fi
dumps_after="$(backup_artifact_count "$PRE_MIGRATE_DUMP_PREFIX")"
test "$dumps_after" -eq "$dumps_before" \
    || fail "the dump count changed ($dumps_before -> $dumps_after) with the escape hatch set"

# The escape hatch skips the BACKUP, not the migration. The schema work still
# has to happen, or the option would be a way to break deployments rather than
# a way to defer backups to a DBA.
if column_exists image "$ESCAPE_HATCH_DRIFT_COLUMN"; then
    fail "with the escape hatch set the schema difference was left unreconciled; the option must skip only the dump"
fi
assert_no_credential_leak "$escape_hatch_log"
pass "the escape hatch skipped the dump, reconciled the schema, and published no artifact"


# --- C. an already-committed revision ----------------------------------------

section "C — an upgrade against an existing revision is dumped before it applies"

head_revision="$(db_query 'SELECT version_num FROM alembic_version;' | tr -d '[:space:]')"
test -n "$head_revision" || fail "alembic_version is empty; there is no committed revision to build on"
note "current head revision: ${head_revision}"

# A revision that looks exactly like one an operator's previous release
# committed. Its body creates a VIEW: SQLAlchemy's get_table_names does not
# report views, so autogenerate cannot see it, and `flask db check` stays clean
# after the upgrade. That is what makes the assertion "upgrade applied this"
# rather than "autogenerate reconciled something".
revision_source="${SCRATCH_DIRECTORY}/seeded-revision.py"
cat >"$revision_source" <<REVISION
"""${SEEDED_REVISION_MESSAGE}

Revision ID: ${SEEDED_REVISION_ID}
Revises: ${head_revision}
"""
from alembic import op


revision = '${SEEDED_REVISION_ID}'
down_revision = '${head_revision}'
branch_labels = None
depends_on = None


def upgrade():
    op.execute('CREATE OR REPLACE VIEW ${SEEDED_REVISION_VIEW} AS SELECT 1 AS applied')


def downgrade():
    op.execute('DROP VIEW IF EXISTS ${SEEDED_REVISION_VIEW}')
REVISION

# Written through the workbench so the file lands with uid 10001 and no
# group/other write bit — migrate-critical.sh refuses to execute an Alembic
# tree another uid could have rewritten, and that refusal is not what is being
# tested here.
k exec --stdin "$WORKBENCH_POD" --container workbench -- \
    bash -c 'set -Eeuo pipefail; umask 022; cat > "$1"; chmod 0644 "$1"' \
    _ "${MIGRATION_PATH}/versions/${SEEDED_REVISION_ID}_e2e_seeded.py" <"$revision_source"

dumps_before="$(backup_artifact_count "$PRE_MIGRATE_DUMP_PREFIX")"

# Restoring the default in the same step: the values change is what rolls the
# pod, and the pre-migration dump gate has to be back ON for the assertion
# below to mean anything.
existing_revision_log="${SCRATCH_DIRECTORY}/existing-revision.log"
upgrade_web_capturing_migrate_log "$existing_revision_log" --set migrations.preMigrateDump=true

grep -Fq 'Schema work is pending' "$existing_revision_log" \
    || fail "a database behind a committed revision was not reported as having pending work"
grep -Fq 'Verified database dump published' "$existing_revision_log" \
    || fail "no pre-migration dump was published before an already-committed revision was applied — this is the exact regression the safety-property change exists to prevent"
grep -Fq 'Schema matches models; no migration needed' "$existing_revision_log" \
    || fail "after applying the committed revision the schema still differed from the models, so this scenario cannot distinguish upgrade from autogenerate"
if grep -Fq 'Model changes detected' "$existing_revision_log"; then
    fail "the committed revision was reconciled by autogenerate rather than applied by upgrade"
fi

dumps_after="$(backup_artifact_count "$PRE_MIGRATE_DUMP_PREFIX")"
test "$dumps_after" -eq $((dumps_before + 1)) \
    || fail "an already-committed revision was applied without exactly one fresh pre-migration dump ($dumps_before -> $dumps_after)"

applied_revision="$(db_query 'SELECT version_num FROM alembic_version;' | tr -d '[:space:]')"
test "$applied_revision" = "$SEEDED_REVISION_ID" \
    || fail "alembic_version is ${applied_revision}, not the seeded revision ${SEEDED_REVISION_ID}"
probe_value="$(db_query "SELECT applied FROM \`${SEEDED_REVISION_VIEW}\`;" | tr -d '[:space:]')"
test "$probe_value" = "1" \
    || fail "the seeded revision's own DDL did not run; ${SEEDED_REVISION_VIEW} returned '${probe_value}'"

# The ordering proof, taken from the ARTIFACT rather than from a log line.
# These images emit no alembic INFO logging — `flask db upgrade` runs silently —
# so "the dump was published before the schema changed" cannot be read off the
# migration output. It can be read off the dump: a recovery artifact taken
# before the upgrade must still carry the OLD alembic revision and must not
# mention the revision that was about to be applied. That is a stronger
# statement than log ordering anyway, because it is about what an operator
# would actually recover.
published_dump="$(newest_backup_artifact "$PRE_MIGRATE_DUMP_PREFIX")"
test -n "$published_dump" || fail "no pre-migration artifact is present to inspect"
if ! backup_artifact_contains "$published_dump" "$head_revision"; then
    fail "the pre-migration dump does not carry the pre-upgrade revision ${head_revision}, so it is not a recovery point for the state before this migration"
fi
if backup_artifact_contains "$published_dump" "$SEEDED_REVISION_ID"; then
    fail "the pre-migration dump already contains ${SEEDED_REVISION_ID}, so it was taken AFTER the revision was applied — the safety property is inverted"
fi
note "recovery artifact ${published_dump} carries revision ${head_revision} and not ${SEEDED_REVISION_ID}"

assert_no_credential_leak "$existing_revision_log"
pass "the committed revision was dumped first — provably, from the artifact — then applied, and its DDL really ran"

# The view was only ever a witness. Dropping it keeps the logical dump the
# restore scenario takes next free of a DEFINER-bearing object, while the
# revision file itself stays in place so alembic_version keeps naming a
# revision that exists.
db_query "DROP VIEW IF EXISTS \`${SEEDED_REVISION_VIEW}\`;" >/dev/null

printf '\nmigration paths: guardedAutogenerate=dumped-then-applied escapeHatch=skipped-dump-only committedRevision=dumped-then-upgraded\n'
