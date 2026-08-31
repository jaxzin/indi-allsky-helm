#!/bin/bash
# Scheduled database backup, run by the chart's CronJob.
#
# Runs as the child of db-maintenance-lock.sh, so the dump, its verification
# and its publication all happen while this Job holds the same shared advisory
# lock the migration path takes (issue #16). `--single-transaction` gives a
# consistent view of ordinary InnoDB DML; it is NOT coordination for concurrent
# ALTER/CREATE/DROP, which is precisely why the lock exists.
#
# It shares dump-publish.sh with the pre-migration dump, so both producers use
# one no-clobber publication primitive. Only the destination prefix and the
# retention rule differ: this one is age-based and scoped to its own prefix, so
# it can never remove a pre-migration recovery artifact.
#
# Like every script in these images this one must never gain `set -x`: it
# handles the database password.

set -o errexit
set -o nounset
# pipefail is load-bearing: without it a mariadb-dump that dies mid-stream
# still leaves the `| gzip` pipeline's status at 0 and a truncated dump would
# be published as a verified backup.
set -o pipefail

# The dump contains every table, including local password hashes and the
# Fernet-encrypted third-party credential fields.
umask 077

# Kept for images run outside this chart. The chart always sets
# INDIALLSKY_BACKUP_DIR to the persistent sibling outside the web docroot.
DEFAULT_BACKUP_DIR="/var/www/html/.state/backups"

# This producer's own final-name prefix. migrate-critical.sh owns "pre-migrate"
# and neither prefix's retention may ever see the other's files.
SCHEDULED_BACKUP_PREFIX="indi-allsky_scheduled"
DEFAULT_RETENTION_DAYS=14

# shellcheck disable=SC1091  # installed alongside this script by the Dockerfile; not resolvable at lint time
source /home/allsky/validators.sh
# shellcheck disable=SC1091  # installed alongside this script by the Dockerfile; not resolvable at lint time
source /home/allsky/db-connection.sh
# shellcheck disable=SC1091  # installed alongside this script by the Dockerfile; not resolvable at lint time
source /home/allsky/dump-publish.sh

db_connection_init

# The in-flight temporary dump is removed on every outcome — success,
# collision, failure and handled signals — so a failed run never leaves an
# artifact behind and never runs retention.
trap dump_cleanup EXIT INT TERM HUP

BACKUP_DIR="${INDIALLSKY_BACKUP_DIR:-$DEFAULT_BACKUP_DIR}"
RETENTION_DAYS="${INDIALLSKY_BACKUP_RETENTION_DAYS:-$DEFAULT_RETENTION_DAYS}"

# A non-numeric value would make `find -mtime` reject its argument mid-run,
# after the dump was already published; catching it here keeps the failure
# ahead of any filesystem change.
case "$RETENTION_DAYS" in
    ''|*[!0-9]*)
        echo "FATAL: INDIALLSKY_BACKUP_RETENTION_DAYS must be a whole number (got ${#RETENTION_DAYS} bytes)" >&2
        exit 1 ;;
esac
if [ "$RETENTION_DAYS" -lt 1 ]; then
    echo "FATAL: INDIALLSKY_BACKUP_RETENTION_DAYS must be at least 1 — retaining zero days would delete the backup this run just published" >&2
    exit 1
fi

dump_require_private_directory INDIALLSKY_BACKUP_DIR "$BACKUP_DIR"

publish_verified_dump "$BACKUP_DIR" "$SCHEDULED_BACKUP_PREFIX"

# Retention is deliberately restricted to this job's prefix, runs only after a
# successful publication, and cannot match a temporary file: those are hidden
# and end in .tmp. migrate-critical.sh owns the separate pre-migration dump
# lifecycle and its count-based retention.
find "$BACKUP_DIR" -maxdepth 1 -type f \
    -name "${SCHEDULED_BACKUP_PREFIX}_*.sql.gz" \
    -mtime "+${RETENTION_DAYS}" -delete

echo "Scheduled database backup complete"
