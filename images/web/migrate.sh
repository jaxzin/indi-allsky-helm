#!/bin/bash
# Schema and first-run bootstrap for indi-allsky, part one of two.
#
# This half is the non-secret preflight: render the configuration, create the
# directories on the data volume, and prove the database answers. It then execs
# db-maintenance-lock.sh, which takes the shared maintenance advisory lock and
# runs migrate-critical.sh — everything that can mutate the schema or publish a
# dump — as its child.
#
# The split exists so the whole database-critical section is inside one lock
# holder's lifetime (issue #16). Preflight deliberately stays outside it: a pod
# waiting five minutes for a cold MariaDB must not be holding a lock that
# blocks the scheduled backup for those five minutes.
#
# The chart runs this as the web pod's initContainer, so it holds the database
# to itself: the gunicorn container and the daemon pod both start only after it
# has exited 0.
#
# Like render-flask-config.sh, this script must never gain `set -x`: it
# handles the database password and prints paths derived from the decrypted
# config dump.

set -o errexit
set -o nounset
set -o pipefail

ALLSKY_DIRECTORY="/home/allsky/indi-allsky"
ALLSKY_ETC="/etc/indi-allsky"
FLASK_CONFIG="${ALLSKY_ETC}/flask.json"

DB_MAINTENANCE_LOCK="/home/allsky/db-maintenance-lock.sh"
MIGRATE_CRITICAL="/home/allsky/migrate-critical.sh"

# Database reachability wait. The cap is generous because a cold cluster may
# be pulling the mariadb image; past it the initContainer exits non-zero and
# the pod's restart policy retries the whole step.
DB_WAIT_ATTEMPTS=100
DB_WAIT_INTERVAL=3
DB_WAIT_LOG_EVERY=10

# shellcheck disable=SC1091  # installed alongside this script by the Dockerfile; not resolvable at lint time
source /home/allsky/validators.sh
# shellcheck disable=SC1091  # installed alongside this script by the Dockerfile; not resolvable at lint time
source /home/allsky/db-connection.sh

# The connection settings the lock and the dump will use, validated here so a
# malformed one fails before any schema work rather than mid-migration.
db_connection_init


# render-flask-config.sh owns every path and connection setting; it fails fast
# and names the offending variable.
/home/allsky/render-flask-config.sh

# Every flask / config.py / usertool.py invocation below has to run from the
# checkout with the venv active: upstream ships no FLASK_APP, so `flask`
# discovers the application from ./app.py in this directory.
cd "$ALLSKY_DIRECTORY"

# shellcheck disable=SC1091  # created by upstream's Dockerfile at image build time; not in this repo
source /home/allsky/venv/bin/activate


# --- effective paths --------------------------------------------------------
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


# --- endpoint agreement -----------------------------------------------------
#
# Host and port come out of the rendered DSN via SQLAlchemy's own parser — the
# same one the application uses. That turns a DSN the app could not parse into
# a failure here, at migration time, rather than at the first web request.
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

DSN_HOST="$(dsn_field host)"
DSN_PORT="$(dsn_field port)"

# The application connects through the DSN; the advisory lock and the dumps
# connect through the maintenance environment. If those two ever named
# different endpoints the lock would serialize a database nobody was migrating,
# so the disagreement is fatal rather than merely surprising.
# shellcheck disable=SC2153  # DB_HOST/DB_PORT are set by db_connection_init in db-connection.sh
if [ "$DSN_HOST" != "$DB_HOST" ] || [ "$DSN_PORT" != "$DB_PORT" ]; then
    echo "FATAL: the rendered database URI and the maintenance environment describe different endpoints" >&2
    exit 1
fi


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


# --- hand over to the locked critical section -------------------------------
#
# exec, not a call: the lock supervisor becomes this container's only process,
# so the kubelet's TERM reaches the thing that owns the lock and the lock is
# released on every shutdown path.
exec "$DB_MAINTENANCE_LOCK" -- "$MIGRATE_CRITICAL"
