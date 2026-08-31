#!/bin/bash
# Atomic, collision-resistant database dump publication (issue #22).
#
# SOURCED, never executed — it defines functions and does nothing else, so it
# carries no `set -o` lines: the sourcing script owns its own shell options.
# Sourcing scripts must also source validators.sh and db-connection.sh first
# and must call db_connection_init before publish_verified_dump.
#
# Both dump producers share this file — the pre-migration dump in
# migrate-critical.sh and the scheduled dump in scheduled-backup.sh — because
# the publication primitive is the whole safety property. Two copies would be
# two chances for one of them to drift back to a clobbering `mv`.
#
# THE PUBLICATION RULE
#
# A dump becomes visible under its final name only as a hard link from an
# already-verified inode. `ln` fails if the final name exists, so publication
# cannot overwrite, cannot race a check-then-rename window, and cannot leave a
# final-looking name pointing at a partial stream. `mv`, `mv -n`,
# unlink-then-link, and redirection or copy straight to the final path are all
# forbidden here for that reason: every one of them can replace an existing
# recovery artifact.
#
# NEVER add `set -x` to a script that sources this: MARIADB_PASSWORD passes
# through here.

# Numeric owner these images run as. Restated rather than derived from `id -u`
# so a container accidentally started as a different user fails the check
# instead of validating itself.
DUMP_EXPECTED_UID=10001

# The dump carries every table, including local password hashes and the
# Fernet-encrypted third-party credential fields, so neither the directory nor
# the artifact is ever group- or world-readable.
DUMP_DIRECTORY_MODE="0700"
DUMP_FILE_MODE="0600"

# Set by publish_verified_dump. The temporary path exists only between
# creation and publication; the sourcing script's trap removes it on every
# outcome, including success, collision, failure and handled signals.
DUMP_TEMPORARY_FILE=""


# Removes the in-flight temporary dump. Idempotent, safe to call from a trap.
dump_cleanup() {
    if [ -n "$DUMP_TEMPORARY_FILE" ]; then
        rm -f -- "$DUMP_TEMPORARY_FILE"
        DUMP_TEMPORARY_FILE=""
    fi
}


# Flushes a file or directory to stable storage. A dump that is only in the
# page cache is not a recovery artifact, and a directory entry that is only in
# the page cache can vanish while the inode it named survives.
#
# `sync` with operands — not bare `sync`, which flushes every filesystem, and
# not `dd conv=fsync`, which cannot open a directory for writing. GNU coreutils
# opens each operand O_RDONLY and fsyncs it, so the same one-liner covers the
# published file and the directory entry that names it.
dump_fsync() {  # $1 = file or directory path
    sync -- "$1"
}


# Absolute, canonical (no symlink component), owned by this uid, and not
# writable by group or other. Applied to every path that comes from the
# environment before anything is read from or written to it, so a substituted
# or re-pointed volume fails loudly rather than silently redirecting a dump or
# a migration tree.
#
# Only the byte count of a rejected path is printed. Paths are not credentials,
# but they are the one place an operator error reliably reveals infrastructure
# layout in a log others can read.
dump_require_safe_directory() {  # $1=variable name  $2=path
    local name="$1" path="$2" resolved metadata owner mode
    case "$path" in
        /*) ;;
        *) printf 'FATAL: %s must be an absolute path (got %d bytes)\n' "$name" "${#path}" >&2
           return 1 ;;
    esac
    if [ ! -d "$path" ]; then
        printf 'FATAL: %s is not an existing directory\n' "$name" >&2
        return 1
    fi
    resolved="$(realpath -- "$path")"
    if [ "$resolved" != "$path" ]; then
        printf 'FATAL: %s resolves through a symlink and is not canonical\n' "$name" >&2
        return 1
    fi
    metadata="$(stat -c '%u:%a' -- "$path")"
    owner="${metadata%%:*}"
    mode="${metadata##*:}"
    if [ "$owner" != "$DUMP_EXPECTED_UID" ]; then
        printf 'FATAL: %s must be owned by uid %s — set securityContext.fsGroup: %s and check the volume\n' \
            "$name" "$DUMP_EXPECTED_UID" "$DUMP_EXPECTED_UID" >&2
        return 1
    fi
    if [ $((8#${mode} & 0022)) -ne 0 ]; then
        printf 'FATAL: %s is group- or world-writable\n' "$name" >&2
        return 1
    fi
}


# Creates the destination directory when absent, tightens it to 0700, then
# applies the same safety checks.
dump_require_private_directory() {  # $1=variable name  $2=path
    local name="$1" path="$2"
    case "$path" in
        /*) ;;
        *) printf 'FATAL: %s must be an absolute path (got %d bytes)\n' "$name" "${#path}" >&2
           return 1 ;;
    esac
    mkdir -p -- "$path" || {
        printf 'FATAL: cannot create %s — the data volume must be writable by uid %s (set fsGroup: %s)\n' \
            "$name" "$DUMP_EXPECTED_UID" "$DUMP_EXPECTED_UID" >&2
        return 1
    }
    chmod "$DUMP_DIRECTORY_MODE" -- "$path"
    dump_require_safe_directory "$name" "$path"
}


# Dumps the configured database and publishes it without clobber, printing the
# final path on success. Callers must already run under `umask 077` and hold
# the maintenance advisory lock.
#
# Not a command substitution anywhere: it sets globals precisely so it runs in
# the caller's shell, where clearing DUMP_TEMPORARY_FILE after publication is
# visible to the caller's trap. A subshell would leave the trap trying to
# delete a path that is now the published inode's only sibling name.
publish_verified_dump() {  # $1=destination directory  $2=final-name prefix
    local directory="$1" prefix="$2"
    local timestamp temporary_name unique_suffix final_file dump_size

    timestamp="$(date -u +%Y%m%dT%H%M%SZ)"

    # Hidden, mode-0600-by-umask, uniquely named, and in the destination
    # directory — so publication below is a same-filesystem link, and a partial
    # stream never carries a final-looking name.
    DUMP_TEMPORARY_FILE="$(mktemp "${directory}/.${prefix}_${timestamp}.XXXXXX.tmp")"
    temporary_name="${DUMP_TEMPORARY_FILE##*/}"
    unique_suffix="${temporary_name%.tmp}"
    unique_suffix="${unique_suffix##*.}"

    # mktemp's suffix makes two runs starting in the same second choose
    # different final names instead of fighting over one.
    final_file="${directory}/${prefix}_${timestamp}_${unique_suffix}.sql.gz"

    # MYSQL_PWD rather than -p: the password would otherwise sit in argv,
    # readable from /proc by anything else in the pod. `--` before the database
    # name so a name beginning with a hyphen cannot become a client option.
    #
    # pipefail in the caller is load-bearing here: without it a mariadb-dump
    # that dies mid-stream still leaves the pipeline status at gzip's 0.
    MYSQL_PWD="$MARIADB_PASSWORD" mariadb-dump \
        "${DB_CLIENT_ARGUMENTS[@]}" \
        --single-transaction \
        --quick \
        --no-tablespaces \
        -- "$DB_NAME" | gzip -c >"$DUMP_TEMPORARY_FILE"

    # A dump that is not a complete, non-empty gzip stream is not a backup.
    gzip -t "$DUMP_TEMPORARY_FILE"
    if [ ! -s "$DUMP_TEMPORARY_FILE" ]; then
        printf 'FATAL: database dump is empty\n' >&2
        return 1
    fi
    chmod "$DUMP_FILE_MODE" "$DUMP_TEMPORARY_FILE"
    dump_fsync "$DUMP_TEMPORARY_FILE"

    # Publication. `ln` refuses an existing destination, so this cannot
    # overwrite a previous artifact and there is no check-then-act window.
    if ! ln -- "$DUMP_TEMPORARY_FILE" "$final_file"; then
        printf 'FATAL: %s already exists — refusing to replace an existing dump\n' "$final_file" >&2
        return 1
    fi

    # The link is only durable once the directory entry itself is flushed.
    dump_fsync "$directory"

    # Unlinking the temporary name now leaves the verified inode reachable
    # solely under its final name. Cleared first so the caller's trap cannot
    # race this removal.
    temporary_name="$DUMP_TEMPORARY_FILE"
    DUMP_TEMPORARY_FILE=""
    rm -f -- "$temporary_name"

    dump_size="$(wc -c <"$final_file" | tr -d '[:space:]')"
    printf 'Verified database dump published: %s (%s bytes)\n' "$final_file" "$dump_size"
}


# Count-based retention, scoped to one prefix. Never touches the other
# producer's prefix and never counts or removes a temporary file: only files
# matching <prefix>_*.sql.gz are candidates, and hidden temporaries end in
# .tmp. Runs only after a successful publication, so it can never prune the
# artifact a migration is about to depend on.
prune_published_dumps() {  # $1=directory  $2=prefix  $3=how many to keep
    local directory="$1" prefix="$2" keep="$3"
    find "$directory" -maxdepth 1 -type f -name "${prefix}_*.sql.gz" -printf '%T@ %p\n' \
        | sort -rn \
        | tail -n "+$((keep + 1))" \
        | cut -d' ' -f2- \
        | xargs -r rm -f --
}
