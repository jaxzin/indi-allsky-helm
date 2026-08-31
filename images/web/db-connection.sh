#!/bin/bash
# Database connection contract for the web image's maintenance scripts.
#
# SOURCED, never executed — it defines one function and does nothing else, so
# it carries no `set -o` lines: the sourcing script owns its own shell options.
#
# This exists because db-maintenance-lock.sh, migrate-critical.sh and
# scheduled-backup.sh all have to talk to the same database with the same
# validated settings and the same TLS posture. Three copies of the same
# environment parsing would be three chances for the lock to be taken on a
# different connection from the one the dump uses — which would silently
# unserialize the two jobs the lock exists to serialize.
#
# It consumes exactly the environment contract render-flask-config.sh already
# defines, through the same validators, so the maintenance path and the
# application path can never disagree about which database they mean.
#
# NEVER add `set -x` to a script that sources this: MARIADB_PASSWORD passes
# through here. No message below echoes a value, a DSN, or a connection URI.

# Certificate bundle shipped by the base image. There is deliberately no
# custom-CA control in v1: an operator needing one has to bake the bundle into
# a derived image, which is a visible decision rather than a silent downgrade.
DB_CA_BUNDLE="/etc/ssl/certs/ca-certificates.crt"

# Populates DB_HOST, DB_PORT, DB_USER, DB_NAME, DB_SSL and the
# DB_CLIENT_ARGUMENTS array (client options only, no database name and no
# credentials). Callers append their own trailing `-- "$DB_NAME"`.
#
# Every validator is the entire right-hand side of its own assignment and none
# is nested inside another's argument list — the calling convention documented
# in validators.sh, where nesting silently yields a validated-looking empty
# value instead of aborting.
db_connection_init() {
    DB_HOST="$(require_nonempty INDIALLSKY_MARIADB_HOST "${INDIALLSKY_MARIADB_HOST:-}")"
    DB_HOST="$(require_charset INDIALLSKY_MARIADB_HOST "$DB_HOST" \
        'a-zA-Z0-9.:_-' 'hostname characters (letters, digits, dot, colon, hyphen, underscore)')"

    DB_PORT="$(require_charset INDIALLSKY_MARIADB_PORT "${INDIALLSKY_MARIADB_PORT:-3306}" \
        '0-9' 'digits')"

    DB_USER="$(require_nonempty MARIADB_USER "${MARIADB_USER:-}")"

    DB_NAME="$(require_nonempty MARIADB_DATABASE "${MARIADB_DATABASE:-}")"
    DB_NAME="$(require_charset MARIADB_DATABASE "$DB_NAME" \
        'a-zA-Z0-9_$-' 'letters, digits, underscore, hyphen and $')"

    DB_SSL="$(require_bool INDIALLSKY_MARIADB_SSL "${INDIALLSKY_MARIADB_SSL:-false}")"

    # Presence only. The value never reaches argv — every client below reads it
    # from MYSQL_PWD, so `-p` can never put it in /proc for the rest of the pod.
    require_nonempty MARIADB_PASSWORD "${MARIADB_PASSWORD:-}" >/dev/null

    DB_CLIENT_ARGUMENTS=(
        --host="$DB_HOST"
        --port="$DB_PORT"
        --user="$DB_USER"
    )
    if [ "$DB_SSL" == "true" ]; then
        # Explicitly verified TLS, never opportunistic: without
        # --ssl-verify-server-cert the client accepts any certificate the
        # server offers, which is indistinguishable from no TLS at all against
        # an attacker who can answer for the database's address.
        DB_CLIENT_ARGUMENTS+=(--ssl-ca="$DB_CA_BUNDLE" --ssl-verify-server-cert)
    fi
}
