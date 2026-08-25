#!/bin/bash
# Schema and first-run bootstrap for indi-allsky. The chart runs this as the
# web pod's initContainer, so it holds the database to itself: the gunicorn
# container and the daemon pod both start only after it has exited 0.
#
# Like render-flask-config.sh, this script must never gain `set -x`: it
# handles the database password and prints paths derived from the decrypted
# config dump.

set -o errexit
set -o nounset
# pipefail is load-bearing, not boilerplate. The pre-migration backup is
# `mariadb-dump ... | gzip > file`; without pipefail a mariadb-dump that dies
# mid-stream still leaves the pipeline exit status at gzip's 0, and the script
# would go on to mutate the schema believing it had a backup. That is exactly
# the safety property this file exists to provide.
set -o pipefail

ALLSKY_DIRECTORY="/home/allsky/indi-allsky"
ALLSKY_ETC="/etc/indi-allsky"
FLASK_CONFIG="${ALLSKY_ETC}/flask.json"

DEFAULT_BACKUP_DIR="/var/www/html/allsky/.state/backups"

# Database reachability wait. The cap is generous because a cold cluster may
# be pulling the mariadb image; past it the initContainer exits non-zero and
# the pod's restart policy retries the whole step.
DB_WAIT_ATTEMPTS=100
DB_WAIT_INTERVAL=3
DB_WAIT_LOG_EVERY=10

# usertool.py's own constraint (misc/usertool.py:109).
MIN_WEB_PASS_LENGTH=8

# Fresh database has 0 users; after `config.py bootstrap` there is exactly one
# — the internal 'system' account it creates. Anything above that means a real
# operator account already exists and must not be re-seeded.
MAX_USER_COUNT_FOR_SEED=1


# render-flask-config.sh owns every path and connection setting; it fails fast
# and names the offending variable.
/home/allsky/render-flask-config.sh

# Every flask / config.py / usertool.py invocation below has to run from the
# checkout with the venv active: upstream ships no FLASK_APP, so `flask`
# discovers the application from ./app.py in this directory.
cd "$ALLSKY_DIRECTORY"

# shellcheck disable=SC1091  # created by upstream's Dockerfile at image build time; not in this repo
source /home/allsky/venv/bin/activate


# --- effective paths and connection details ---------------------------------
#
# Read back what the render script decided instead of re-deriving it here, so
# the defaults exist in exactly one place.
MIGRATION_FOLDER="$(jq -er '.MIGRATION_FOLDER' "$FLASK_CONFIG")"
IMAGE_FOLDER="$(jq -er '.INDI_ALLSKY_IMAGE_FOLDER' "$FLASK_CONFIG")"

# Create the directories this script and the capture daemon write into.
# Upstream did it from its entrypoints with `sudo chown`; sudo is purged from
# these images, so the volume itself has to be writable by uid/gid 10001.
# images/daemon/entrypoint-daemon.sh repeats the IMAGE_FOLDER line for the
# capture pod, which mounts the same volume but does not run this script.
# Only the migration folder's PARENT is created here — `flask db init` creates
# the leaf itself, and alembic refuses to initialise into a directory that
# already exists and is non-empty.
for dir in "$IMAGE_FOLDER" "$(dirname "$MIGRATION_FOLDER")"; do
    mkdir -p "$dir" || {
        echo "FATAL: cannot create ${dir} — the data volume must be writable by uid 10001 (set fsGroup: 10001)" >&2
        exit 1
    }
done

# Host and port come out of the rendered DSN via SQLAlchemy's own parser — the
# same one the application uses. That keeps the port default in one place and
# turns a DSN the app could not parse into a failure here, at migration time,
# rather than at the first web request.
# make_url's failure mode is version-dependent — it has raised ValueError,
# ArgumentError and (on malformed ports) its own subclasses across releases —
# so every exception is turned into one clean FATAL rather than a traceback
# whose top line changes with the pinned SQLAlchemy. The exception text is
# deliberately NOT echoed: the URI it describes contains the database password.
dsn_field() {  # $1 = SQLAlchemy URL attribute name
    python3 -c 'import json, sys
from sqlalchemy.engine import make_url
field = sys.argv[2]
try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        url = make_url(json.load(handle)["SQLALCHEMY_DATABASE_URI"])
except Exception as exc:
    sys.exit("FATAL: rendered database URI is unparseable ({0})".format(type(exc).__name__))
value = getattr(url, field, None)
if value is None:
    sys.exit("FATAL: rendered database URI has no " + field)
print(value)' "$FLASK_CONFIG" "$1"
}

DB_HOST="$(dsn_field host)"
DB_PORT="$(dsn_field port)"


# --- wait for the database --------------------------------------------------
#
# Connection refused is the expected state while mariadb starts, so the error
# is captured rather than printed on every attempt — and it is captured, not
# discarded: the last one is echoed on the progress lines and in the FATAL, so
# a wrong host or a TLS mismatch is diagnosable from the pod log. Host and
# port reach python through argv, never through string interpolation.
attempt=0
db_error=""
until db_error="$(python3 -c 'import socket, sys
try:
    socket.create_connection((sys.argv[1], int(sys.argv[2])), 3).close()
except OSError as exc:
    sys.exit(str(exc))' "$DB_HOST" "$DB_PORT" 2>&1 >/dev/null)"; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge "$DB_WAIT_ATTEMPTS" ]; then
        echo "FATAL: database ${DB_HOST}:${DB_PORT} unreachable after $((DB_WAIT_ATTEMPTS * DB_WAIT_INTERVAL))s: ${db_error}" >&2
        exit 1
    fi
    if [ $((attempt % DB_WAIT_LOG_EVERY)) -eq 0 ]; then
        echo "Still waiting for database ${DB_HOST}:${DB_PORT} ($((attempt * DB_WAIT_INTERVAL))s elapsed): ${db_error}"
    fi
    sleep "$DB_WAIT_INTERVAL"
done
echo "Database ${DB_HOST}:${DB_PORT} is reachable"


# --- migration history ------------------------------------------------------
#
# Test the artifact, not the directory: MIGRATION_FOLDER lives on the shared
# data volume, and a subPath mount (or a previous run that failed between
# mkdir and init) leaves an existing-but-empty directory. A `-d` test would
# skip init there and then die at `db upgrade`.
if [[ ! -f "${MIGRATION_FOLDER}/env.py" ]]; then
    echo "No migration history at ${MIGRATION_FOLDER}; initialising"
    flask db init
fi

# Upgrade FIRST, then check. The order matters: `flask db check` compares the
# models against the live database, so on a database that is merely behind the
# committed revisions it reports a difference that `upgrade` — not a new
# autogenerated revision — is the correct answer to. Checking first would
# autogenerate a duplicate of a revision that already exists.
flask db upgrade head

if flask db check; then
    echo "Schema matches models; no migration needed"
else
    echo "Model changes detected; generating guarded migration"

    # v1 compromise: generating revisions at runtime means the schema history
    # is produced on the operator's cluster rather than reviewed in CI.
    # CI-committed revisions replace this block and are a hard prerequisite
    # for the first UPSTREAM_VERSION bump — tracked in issue #9. Until then
    # the dump below is what makes an unreviewed migration recoverable.
    # Strict true|false, for the same reason as PRE_MIGRATE_DUMP_KEEP below. A
    # loose `== "true"` test treats True, TRUE, 1, yes and every typo as "skip
    # the dump", so a mistyped value silently discards the backup and then
    # mutates the schema, at exit 0 — this file's safety property inverted.
    # Only the length is reported, never the value. This variable is consumed
    # nowhere but here, so render-flask-config.sh's require_bool never sees it.
    PRE_MIGRATE_DUMP="${INDIALLSKY_PRE_MIGRATE_DUMP:-true}"
    case "$PRE_MIGRATE_DUMP" in
        true|false) ;;
        *) echo "FATAL: INDIALLSKY_PRE_MIGRATE_DUMP must be exactly \"true\" or \"false\" (got ${#PRE_MIGRATE_DUMP} bytes) — a typo here would silently skip the pre-migration backup" >&2
           exit 1 ;;
    esac

    if [ "$PRE_MIGRATE_DUMP" == "true" ]; then
        DUMP_DIR="${INDIALLSKY_BACKUP_DIR:-$DEFAULT_BACKUP_DIR}"
        PRE_MIGRATE_DUMP_KEEP="${INDIALLSKY_PRE_MIGRATE_DUMP_KEEP:-8}"

        # A retention of 0 would prune the dump taken moments ago, immediately
        # before the schema is mutated — the safety property inverted. A
        # non-numeric value would make the arithmetic below silently mean 0.
        case "$PRE_MIGRATE_DUMP_KEEP" in
            ''|*[!0-9]*)
                echo "FATAL: INDIALLSKY_PRE_MIGRATE_DUMP_KEEP must be a whole number (got ${#PRE_MIGRATE_DUMP_KEEP} bytes)" >&2
                exit 1 ;;
        esac
        if [ "$PRE_MIGRATE_DUMP_KEEP" -lt 1 ]; then
            echo "FATAL: INDIALLSKY_PRE_MIGRATE_DUMP_KEEP must be at least 1 — retaining zero dumps would delete the backup this migration depends on. To skip the dump entirely, set INDIALLSKY_PRE_MIGRATE_DUMP=false." >&2
            exit 1
        fi

        mkdir -p "$DUMP_DIR"
        DUMP_FILE="${DUMP_DIR}/pre-migrate_$(date +%Y%m%d_%H%M%S).sql.gz"

        # MYSQL_PWD rather than -p: the password would otherwise sit in argv,
        # readable from /proc by anything else in the pod.
        MYSQL_PWD="$MARIADB_PASSWORD" mariadb-dump \
            --single-transaction --no-tablespaces \
            -h "$DB_HOST" -P "$DB_PORT" \
            -u "$MARIADB_USER" "$MARIADB_DATABASE" \
            | gzip > "$DUMP_FILE"

        # A dump that is not a complete, non-empty gzip stream is not a backup.
        gzip -t "$DUMP_FILE"
        [ -s "$DUMP_FILE" ]
        echo "Pre-migrate dump complete: ${DUMP_FILE} ($(stat -c %s "$DUMP_FILE") bytes)"

        # shellcheck disable=SC2012  # filenames are generated above from strftime — newline/glob-free; ls -t is the portable mtime sort here
        ls -1t "$DUMP_DIR"/pre-migrate_*.sql.gz \
            | tail -n "+$((PRE_MIGRATE_DUMP_KEEP + 1))" \
            | xargs -r rm --
    fi

    flask db revision --autogenerate -m "runtime autogenerate $(date +%Y-%m-%dT%H:%M:%S%z)"
    flask db upgrade head
fi


# --- initial configuration --------------------------------------------------
#
# `config.py bootstrap` exits 1 in two very different situations: when a
# configuration already exists (indi_allsky/config.py:1471, the normal
# second-run case) and when it genuinely failed. A bare `|| true` cannot tell
# them apart and would let a broken deployment continue. Probing with
# `dumpfile` distinguishes them: it succeeds only when a committed config row
# is readable. Its output is discarded to /dev/null because a config dump
# contains third-party credentials decrypted.
if ! ./config.py bootstrap --image_folder "$IMAGE_FOLDER"; then
    ./config.py dumpfile -o /dev/null >/dev/null 2>&1 \
        || { echo "FATAL: config.py bootstrap failed and no existing config is readable" >&2; exit 1; }
    echo "Configuration already initialized; continuing"
fi


# --- config overlay ---------------------------------------------------------
#
# The overlay is a ConfigMap mounted by the chart. `jq -s '.[0] * .[1]'` merges
# objects recursively but REPLACES arrays wholesale, and cannot remove a key.
OVERLAY="${INDIALLSKY_CONFIG_OVERLAY:-/etc/indi-allsky/config-overlay.json}"
if [[ -f "$OVERLAY" ]]; then
    echo "Applying config overlay ${OVERLAY}"
    umask 077
    TMP_DUMP=$(mktemp --suffix=.json)
    TMP_MERGED=$(mktemp --suffix=.json)
    # config.py dump output contains decrypted credentials — always clean up, even on failure
    trap 'rm -f -- "$TMP_DUMP" "$TMP_MERGED"' EXIT INT TERM
    ./config.py dump > "$TMP_DUMP"
    jq -s '.[0] * .[1]' "$TMP_DUMP" "$OVERLAY" > "$TMP_MERGED"
    ./config.py load -c "$TMP_MERGED" --force
fi


# --- admin account ----------------------------------------------------------
#
# usertool.py validates interactively: an empty or short password, a username
# with spaces, or a malformed email all drop it into input()/getpass() rather
# than failing. In an initContainer with no tty that is a hang or an EOFError
# traceback, neither of which tells the operator what was wrong. Check the
# same constraints up front (misc/usertool.py:44, :109, :132) and redirect
# stdin from /dev/null so any remaining prompt fails immediately instead of
# blocking the pod.
#
# LOCAL_AUTH_ENABLE is not re-validated here: render-flask-config.sh already
# put it through require_bool and aborted before this script got this far.
#
# The credential guards live INSIDE the seeding branch, not above it. Two
# reviewers reached this placement from opposite directions, so the
# reasoning is recorded here rather than re-litigated:
#
#   * Hoisting them earlier would fail a credential typo in ~1s instead of
#     ~7s, before any schema work — a real diagnosis-speed gain.
#   * But whether seeding applies at all is unknowable until the database is
#     up and counted. On an already-seeded deployment whose bootstrap secret
#     has since been rotated away, hoisted guards turn "2 accounts exist;
#     not seeding" into a FATAL, bricking the initContainer on every restart
#     and silently making INDIALLSKY_WEB_PASS permanently required — a
#     contract change nobody agreed to.
#
# Validation may therefore only gate the seeding *action*, which is what this
# ordering does. The diagnosis-speed loss is bounded by the DB wait and is
# the cheaper of the two costs.
if [ "${INDIALLSKY_LOCAL_AUTH_ENABLE:-true}" == "true" ] && [ -n "${INDIALLSKY_WEB_USER:-}" ]; then
    USER_COUNT=$(./config.py user_count)

    if [ "$USER_COUNT" -le "$MAX_USER_COUNT_FOR_SEED" ]; then
        WEB_PASS="${INDIALLSKY_WEB_PASS:-}"
        WEB_EMAIL="${INDIALLSKY_WEB_EMAIL:-admin@example.com}"

        case "$INDIALLSKY_WEB_USER" in *[[:space:]]*)
            echo "FATAL: INDIALLSKY_WEB_USER must not contain spaces" >&2; exit 1 ;;
        esac
        if [ "${#WEB_PASS}" -lt "$MIN_WEB_PASS_LENGTH" ]; then
            echo "FATAL: INDIALLSKY_WEB_PASS must be at least ${MIN_WEB_PASS_LENGTH} characters" >&2
            exit 1
        fi
        if ! printf '%s' "$WEB_EMAIL" | grep -Eq '^[^@]+@[^@]+\.[^@]+$'; then
            echo "FATAL: INDIALLSKY_WEB_EMAIL is not a valid address" >&2
            exit 1
        fi

        echo "Seeding admin account ${INDIALLSKY_WEB_USER}"
        ./misc/usertool.py adduser -u "$INDIALLSKY_WEB_USER" -p "$WEB_PASS" \
            -f "${INDIALLSKY_WEB_NAME:-Admin}" -e "$WEB_EMAIL" </dev/null
        ./misc/usertool.py setadmin -u "$INDIALLSKY_WEB_USER" </dev/null
    else
        echo "${USER_COUNT} accounts already exist; not seeding"
    fi
fi

echo "Migration and bootstrap complete"
