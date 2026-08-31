#!/bin/bash
# Shared database-maintenance serialization (issue #16).
#
#     db-maintenance-lock.sh -- <command> [args...]
#
# Holds one deterministic, database-scoped MariaDB advisory lock for the entire
# lifetime of <command>, then releases it. Both writers that can touch the
# schema or publish a dump go through this wrapper — the web pod's migration
# initContainer and the scheduled backup CronJob — so a migration and a dump
# can never run against the same database at the same time.
#
# WHY A LIVE SESSION, NOT A ONE-SHOT QUERY
#
# MariaDB releases a named lock when the connection that took it ends. A
# `mariadb -e "SELECT GET_LOCK(...)"` therefore acquires and immediately drops
# the lock as the client exits, which looks like serialization and provides
# none. The lock has to be held by a connection that outlives the protected
# work, so this script keeps ONE client process alive across the child through
# a pair of FIFOs and speaks to it statement by statement.
#
# WHY BASH AND THE mariadb CLIENT, NOT PYTHON AND A CONNECTOR
#
# The protected commands are external processes (`flask db upgrade`,
# `mariadb-dump`), so the supervisor is a process supervisor either way. The
# mariadb client is already a hard dependency of both call sites, works
# identically in every image that can run a dump, and needs no library import
# to hold a session open. A connector-based supervisor would add a Python
# runtime dependency to a script whose entire job is subprocess lifecycle.
#
# Like every script in these images this one must never gain `set -x`: it
# handles the database password. No message here echoes a value, a DSN, or a
# connection URI.

set -o errexit
set -o nounset
set -o pipefail

# shellcheck disable=SC1091  # installed alongside this script by the Dockerfile; not resolvable at lint time
source /home/allsky/validators.sh
# shellcheck disable=SC1091  # installed alongside this script by the Dockerfile; not resolvable at lint time
source /home/allsky/db-connection.sh

# --- fixed internal constants ------------------------------------------------
#
# Deliberately not public chart values: they describe how long a cooperating
# maintenance job may block, which is an implementation property of these two
# jobs, not something an operator tunes.

# The lock identity is namespaced so it cannot collide with an unrelated
# application's named lock on a shared server, versioned so a future protocol
# change can coexist, and scoped to the database name so two releases pointing
# at different schemas on one server do not serialize against each other.
# MariaDB caps a lock name at 64 bytes; prefix (24) + digest (32) = 56.
LOCK_NAME_PREFIX="indi-allsky:db-maint:v1:"
LOCK_NAME_DIGEST_LENGTH=32

# GET_LOCK blocks server-side for its timeout argument. Short slices keep the
# progress log and signal handling responsive inside a long total wait.
LOCK_ACQUIRE_SLICE_SECONDS=5
LOCK_ACQUIRE_DEADLINE_SECONDS=300
LOCK_WAIT_LOG_EVERY_SECONDS=30

# A reply to a lock statement is a single line from a client that is already
# connected; anything slower than this means the session is gone.
LOCK_REPLY_TIMEOUT_SECONDS=30

# Grace given to the protected process group after TERM before KILL.
CHILD_TERM_GRACE_SECONDS=10

# sysexits.h. Distinguishes "the safety control itself failed" (69) and "the
# lock was busy, retry later" (75) from any status the child produces.
EX_USAGE=64
EX_UNAVAILABLE=69
EX_TEMPFAIL=75


fatal() {  # $1=exit status  $2=message
    printf 'FATAL: %s\n' "$2" >&2
    exit "$1"
}


# --- command grammar ---------------------------------------------------------

if [ "$#" -lt 2 ] || [ "$1" != "--" ]; then
    printf 'FATAL: usage: %s -- <command> [args...]\n' "${0##*/}" >&2
    exit "$EX_USAGE"
fi
shift


# --- connection details ------------------------------------------------------

db_connection_init

# sha256 hex only — the lock name can never contain a quote, so interpolating
# it into the statements below cannot change their shape. The database name
# itself is hashed rather than embedded so a name containing SQL-significant
# characters (or exceeding the 64-byte lock-name cap) cannot do so either.
LOCK_NAME="${LOCK_NAME_PREFIX}$(
    printf '%s' "$DB_NAME" | sha256sum | cut -c1-"$LOCK_NAME_DIGEST_LENGTH"
)"

# --unbuffered is load-bearing: without it the client buffers its result and
# this script waits forever for a reply that was already computed.
client_arguments=(
    --batch
    --skip-column-names
    --unbuffered
    "${DB_CLIENT_ARGUMENTS[@]}"
    # `--` before the database, so a name beginning with a hyphen can never be
    # reinterpreted as a client option.
    -- "$DB_NAME"
)


# --- lock session ------------------------------------------------------------

session_directory=""
session_pid=""
child_pid=""
lock_held=false
forwarded_signal=""

# shellcheck disable=SC2329  # reached through `trap`, which shellcheck does not follow
cleanup() {
    local status=$?
    release_lock || status="$EX_UNAVAILABLE"
    close_session
    if [ -n "$session_directory" ]; then
        rm -rf -- "$session_directory"
        session_directory=""
    fi
    exit "$status"
}

# shellcheck disable=SC2329  # reached through `trap`, which shellcheck does not follow
close_session() {
    if [ -n "${lock_in:-}" ]; then
        exec {lock_in}>&-
        lock_in=""
    fi
    if [ -n "${lock_out:-}" ]; then
        exec {lock_out}<&-
        lock_out=""
    fi
    if [ -n "$session_pid" ]; then
        # Closing the request FIFO ends the client's stdin, so it exits by
        # itself; the wait reaps it and its connection close is the backstop
        # that frees the lock even if RELEASE_LOCK never ran.
        wait "$session_pid" 2>/dev/null || true
        session_pid=""
    fi
}

# Sends one statement and returns its single-column reply. A closed or wedged
# session is a non-zero return, never a silently empty answer.
lock_query() {  # $1 = SQL statement
    local reply
    printf '%s\n' "$1" >&"$lock_in" || return 1
    IFS= read -r -t "$LOCK_REPLY_TIMEOUT_SECONDS" -u "$lock_out" reply || return 1
    printf '%s' "$reply"
}

# shellcheck disable=SC2329  # reached through `trap`, which shellcheck does not follow
release_lock() {
    local reply
    [ "$lock_held" == true ] || return 0
    lock_held=false
    if ! reply="$(lock_query "SELECT RELEASE_LOCK('${LOCK_NAME}');")"; then
        printf 'FATAL: database maintenance advisory lock session ended before it could be released\n' >&2
        return 1
    fi
    case "$reply" in
        1)
            printf 'Released the database maintenance advisory lock\n'
            return 0 ;;
        *)
            # 0 = held by another connection, NULL = never existed. Either means
            # this process lost ownership while it believed it held the lock.
            printf 'FATAL: database maintenance advisory lock was not held at release time\n' >&2
            return 1 ;;
    esac
}

# Handled signals are forwarded to the whole protected process group so a child
# that spawned helpers takes them down with it. Deeper escape containment (a
# descendant that starts its own session) is tracked in issue #27.
# shellcheck disable=SC2329  # reached through `trap`, which shellcheck does not follow
forward_signal() {  # $1 = signal name
    forwarded_signal="$1"
    if [ -n "$child_pid" ]; then
        printf 'Received SIG%s; stopping the protected command\n' "$1" >&2
        kill -s "$1" -- "-${child_pid}" 2>/dev/null || true
    fi
}

trap cleanup EXIT
trap 'forward_signal TERM' TERM
trap 'forward_signal INT' INT
trap 'forward_signal HUP' HUP

session_directory="$(mktemp -d)"
chmod 0700 "$session_directory"
mkfifo -m 0600 "${session_directory}/request" "${session_directory}/reply"

# MYSQL_PWD rather than -p: the password would otherwise sit in argv, readable
# from /proc by anything else in the pod.
MYSQL_PWD="$MARIADB_PASSWORD" mariadb "${client_arguments[@]}" \
    <"${session_directory}/request" >"${session_directory}/reply" &
session_pid=$!

# Both opens rendezvous with the client's own two opens; neither can complete
# until the client process is actually running.
exec {lock_in}>"${session_directory}/request"
exec {lock_out}<"${session_directory}/reply"


# --- acquisition -------------------------------------------------------------

elapsed=0
while :; do
    if ! reply="$(lock_query "SELECT GET_LOCK('${LOCK_NAME}', ${LOCK_ACQUIRE_SLICE_SECONDS});")"; then
        fatal "$EX_UNAVAILABLE" "database maintenance advisory lock session is unusable — check that ${DB_HOST}:${DB_PORT} is one stable writable primary"
    fi
    case "$reply" in
        1) break ;;
        0) ;;  # another cooperating job holds it; keep trying within the deadline
        *)
            # NULL: an error occurred (killed thread, bad name). Never retried —
            # a lock the server refused to evaluate is not contention.
            fatal "$EX_UNAVAILABLE" "database maintenance advisory lock could not be evaluated by the server" ;;
    esac

    elapsed=$((elapsed + LOCK_ACQUIRE_SLICE_SECONDS))
    if [ "$elapsed" -ge "$LOCK_ACQUIRE_DEADLINE_SECONDS" ]; then
        fatal "$EX_TEMPFAIL" "database maintenance advisory lock unavailable after ${LOCK_ACQUIRE_DEADLINE_SECONDS}s — another migration or scheduled backup is still running"
    fi
    if [ $((elapsed % LOCK_WAIT_LOG_EVERY_SECONDS)) -eq 0 ]; then
        printf 'Still waiting for database maintenance advisory lock (%ss elapsed)\n' "$elapsed"
    fi
done
lock_held=true
printf 'Holding the database maintenance advisory lock\n'


# --- protected command -------------------------------------------------------

# Job control gives the child its own process group, which is what makes
# signal forwarding reach its descendants. The session FIFOs are closed in the
# child so nothing it starts can keep the lock connection open behind us.
set -m
"$@" {lock_in}>&- {lock_out}<&- &
child_pid=$!
set +m

child_status=0
while :; do
    set +o errexit
    wait "$child_pid"
    child_status=$?
    set -o errexit
    # `wait` returns 128+n when a trapped signal interrupts it. Our handler has
    # already forwarded that signal to the child's group, so keep waiting for
    # the child's own status rather than reporting the interruption as one.
    if [ "$child_status" -gt 128 ] && [ -n "$forwarded_signal" ] \
        && kill -0 "$child_pid" 2>/dev/null; then
        continue
    fi
    break
done

if kill -0 "$child_pid" 2>/dev/null; then
    kill -s TERM -- "-${child_pid}" 2>/dev/null || true
    sleep "$CHILD_TERM_GRACE_SECONDS"
    kill -s KILL -- "-${child_pid}" 2>/dev/null || true
fi
child_pid=""

printf 'Protected command exited with status %s\n' "$child_status"

# cleanup() releases the lock and propagates this status, or replaces it with
# EX_UNAVAILABLE if the release itself failed — a lock the server did not
# confirm released is a safety-control failure, not a successful run.
exit "$child_status"
