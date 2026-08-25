#!/bin/bash
# Render /etc/indi-allsky/flask.json from the upstream template plus the
# container's environment. Shared verbatim by the daemon and web images: both
# entrypoints (and the web image's migrate.sh initContainer) run this first,
# so there is exactly one definition of the flask config contract.
#
# NEVER add `set -x` to this script. It handles SECRET_KEY, PASSWORD_KEY, the
# database password and the OIDC client secret; command tracing would print
# every one of them into the pod log, where anyone with `kubectl logs` can
# read them. For the same reason no error message in this file ever echoes the
# offending value — only its byte count.

set -o errexit
set -o nounset
set -o pipefail

# Paths baked into the images by upstream's Dockerfiles.
ALLSKY_DIRECTORY="/home/allsky/indi-allsky"
ALLSKY_ETC="/etc/indi-allsky"

# The chart mounts one data volume at HTDOCS_FOLDER, shared by the daemon and
# web pods. The .state subtree holds everything that must survive a restart but
# is not user-visible content: the Alembic migration tree and the pre-migration
# database dumps. Upstream puts migrations in /var/lib/indi-allsky, which is a
# per-container VOLUME in its compose stack and therefore not shared — in
# Kubernetes it has to live on the shared PVC or the daemon and web pods
# disagree about the schema history. Alembic revisions are generated at runtime
# (upstream ships none), so losing this directory loses the schema history.
DOCROOT_FOLDER="/var/www/html"
HTDOCS_FOLDER="${DOCROOT_FOLDER}/allsky"

DEFAULT_IMAGE_FOLDER="${HTDOCS_FOLDER}/images"
DEFAULT_MIGRATION_FOLDER="${HTDOCS_FOLDER}/.state/migrations"

# flask.json is 0600, not upstream's 0660: it carries SECRET_KEY,
# PASSWORD_KEY, the database DSN (with credentials) and the OIDC client
# secret. Every container that reads it runs as uid 10001, so nothing needs
# the group bit.
FLASK_CONFIG_MODE="600"


# --- typed validation -------------------------------------------------------
#
# jq's --argjson accepts ANY well-formed JSON, so an operator typo turns into a
# silent fail-open instead of an error:
#   * OIDC_ALLOWED_GROUPS=null    -> falsy at auth_views.py:238, so the group
#                                    allow-list stops filtering and every IdP
#                                    user may log in.
#   * OIDC_ADMIN_GROUPS="admins"  -> truthy at auth_views.py:291, where
#                                    set("admins") is a set of CHARACTERS, so
#                                    any group sharing one letter grants admin.
# Validate into a variable before jq ever sees the value.
#
# The `VAR=$(...)` form is load-bearing: a failing command substitution in a
# plain assignment makes the assignment fail, which errexit turns into an
# abort. The same substitution used inline in an argument list (jq --argjson x
# "$(require_bool ...)") does NOT abort — the exit status belongs to jq.

require_bool() {   # $1=name $2=value — value must be exactly true|false
    case "$2" in
        true|false) printf '%s' "$2" ;;
        *) printf 'FATAL: %s must be exactly "true" or "false" (got %d bytes)\n' "$1" "${#2}" >&2; exit 1 ;;
    esac
}

require_string_array() {  # $1=name $2=value — JSON array of strings
    printf '%s' "$2" | jq -e 'type == "array" and all(.[]; type == "string")' >/dev/null \
        || { printf 'FATAL: %s must be a JSON array of strings, e.g. ["group1"]\n' "$1" >&2; exit 1; }
    printf '%s' "$2"
}

require_nonempty() {  # $1=name $2=value — must not be the empty string
    if [ -z "$2" ]; then
        printf 'FATAL: %s must be set and non-empty\n' "$1" >&2
        exit 1
    fi
    printf '%s' "$2"
}


# --- database connection ----------------------------------------------------
#
# Two naming conventions meet here, both inherited from upstream's single
# shared .env file:
#   * bare MARIADB_USER / MARIADB_PASSWORD / MARIADB_DATABASE are the official
#     mariadb image's own environment contract — the database container reads
#     those exact names to provision the user and schema, so the app side must
#     use them verbatim to talk about the same account.
#   * INDIALLSKY_MARIADB_* are app-side connection settings (host, port, TLS,
#     charset, collation) that the mariadb image has no equivalent for.

DB_USER="$(require_nonempty MARIADB_USER "${MARIADB_USER:-}")"
DB_PASS="$(require_nonempty MARIADB_PASSWORD "${MARIADB_PASSWORD:-}")"
DB_NAME="$(require_nonempty MARIADB_DATABASE "${MARIADB_DATABASE:-}")"
DB_HOST="$(require_nonempty INDIALLSKY_MARIADB_HOST "${INDIALLSKY_MARIADB_HOST:-}")"
DB_PORT="${INDIALLSKY_MARIADB_PORT:-3306}"
DB_CHARSET="${INDIALLSKY_MARIADB_CHARSET:-utf8mb4}"
DB_COLLATION="${INDIALLSKY_MARIADB_COLLATION:-utf8mb4_unicode_ci}"
DB_SSL="$(require_bool INDIALLSKY_MARIADB_SSL "${INDIALLSKY_MARIADB_SSL:-false}")"

# Percent-encode the URI userinfo and path segments. Deliberate divergence
# from upstream docker/start_gunicorn.sh, which interpolates these raw: a
# generated password containing @ : / ? & # or % silently re-points or
# truncates the DSN rather than failing (SQLAlchemy's make_url raises on, for
# example, 'p@ss:w/rd#1?x%y'), so a random password can turn into an
# unexplained connection error or a connection to the wrong host.
DB_USER_ENC="$(jq -rn --arg v "$DB_USER" '$v|@uri')"
DB_PASS_ENC="$(jq -rn --arg v "$DB_PASS" '$v|@uri')"
DB_NAME_ENC="$(jq -rn --arg v "$DB_NAME" '$v|@uri')"

if [ "$DB_SSL" == "true" ]; then
    SQLALCHEMY_DATABASE_URI="mysql+mysqlconnector://${DB_USER_ENC}:${DB_PASS_ENC}@${DB_HOST}:${DB_PORT}/${DB_NAME_ENC}?ssl_ca=/etc/ssl/certs/ca-certificates.crt&ssl_verify_identity&charset=${DB_CHARSET}&collation=${DB_COLLATION}"
else
    SQLALCHEMY_DATABASE_URI="mysql+mysqlconnector://${DB_USER_ENC}:${DB_PASS_ENC}@${DB_HOST}:${DB_PORT}/${DB_NAME_ENC}?charset=${DB_CHARSET}&collation=${DB_COLLATION}"
fi


# --- flask / auth settings --------------------------------------------------

SECRET_KEY="$(require_nonempty INDIALLSKY_FLASK_SECRET_KEY "${INDIALLSKY_FLASK_SECRET_KEY:-}")"
PASSWORD_KEY="$(require_nonempty INDIALLSKY_FLASK_PASSWORD_KEY "${INDIALLSKY_FLASK_PASSWORD_KEY:-}")"

AUTH_ALL_VIEWS="$(require_bool INDIALLSKY_FLASK_AUTH_ALL_VIEWS "${INDIALLSKY_FLASK_AUTH_ALL_VIEWS:-false}")"
LOCAL_AUTH_ENABLE="$(require_bool INDIALLSKY_LOCAL_AUTH_ENABLE "${INDIALLSKY_LOCAL_AUTH_ENABLE:-true}")"

# Session and remember-me cookies are marked Secure together: splitting them
# would leave the long-lived remember-me cookie travelling in clear while the
# session cookie was protected. Default true; false is only for deliberately
# plain-HTTP deployments, where true makes login impossible because the
# browser never returns the cookie.
SESSION_COOKIE_SECURE="$(require_bool INDIALLSKY_FLASK_SESSION_COOKIE_SECURE "${INDIALLSKY_FLASK_SESSION_COOKIE_SECURE:-true}")"

# Upstream's template ships ADMIN_NETWORKS pre-populated with the RFC1918 and
# CGNAT ranges, and upstream trusts X-Forwarded-For unconditionally while also
# auto-trusting the pod's own interface subnets via psutil. On a cluster that
# turns "came from a private address" into "is an admin" for anything that can
# set a header. Defaulting to [] is a mitigation, not an elimination: it
# removes the blanket grant and makes operators opt back in explicitly.
ADMIN_NETWORKS="$(require_string_array INDIALLSKY_ADMIN_NETWORKS "${INDIALLSKY_ADMIN_NETWORKS:-[]}")"

OIDC_ENABLE="$(require_bool INDIALLSKY_OIDC_ENABLE "${INDIALLSKY_OIDC_ENABLE:-false}")"
# OIDC_AUTO_LOGIN is absent from upstream's flask.json_template but is honoured
# at indi_allsky/flask/auth_views.py:76, so it is rendered explicitly here.
OIDC_AUTO_LOGIN="$(require_bool INDIALLSKY_OIDC_AUTO_LOGIN "${INDIALLSKY_OIDC_AUTO_LOGIN:-false}")"
OIDC_ALLOWED_GROUPS="$(require_string_array INDIALLSKY_OIDC_ALLOWED_GROUPS "${INDIALLSKY_OIDC_ALLOWED_GROUPS:-[]}")"
OIDC_ADMIN_GROUPS="$(require_string_array INDIALLSKY_OIDC_ADMIN_GROUPS "${INDIALLSKY_OIDC_ADMIN_GROUPS:-[]}")"

IMAGE_FOLDER="${INDIALLSKY_IMAGE_FOLDER:-$DEFAULT_IMAGE_FOLDER}"
MIGRATION_FOLDER="${INDIALLSKY_MIGRATION_FOLDER:-$DEFAULT_MIGRATION_FOLDER}"


# NOTE: this script deliberately does NOT create IMAGE_FOLDER or the .state
# tree that MIGRATION_FOLDER lives in.
# Rendering the flask config must not depend on the data volume being mounted —
# the gunicorn container, the migrate initContainer and the capture daemon all
# render, but only the last two write to the data volume, and none of the three
# images ships a /var/www at all. Creating the directories here would make a
# missing data mount surface as "cannot render the config", which is both the
# wrong diagnosis and untestable in isolation. The writers create their own
# directories (images/web/migrate.sh, images/daemon/entrypoint-daemon.sh) from
# the effective paths this script writes into flask.json, so the defaults still
# live in exactly one place: here.


# --- render -----------------------------------------------------------------

mkdir -p "$ALLSKY_ETC" || {
    printf 'FATAL: cannot create %s — mount an emptyDir there and set fsGroup: 10001\n' "$ALLSKY_ETC" >&2
    exit 1
}

# Write with no group/other bits from the moment of creation, so the secrets
# are never briefly world-readable between creat() and chmod().
umask 0077

# Staged in the destination directory (not /tmp) so the install is a
# same-filesystem rename, and so a partial render is never visible as
# flask.json. Removed on every exit path, including the failure ones.
TMP_FLASK="${ALLSKY_ETC}/.flask.json.tmp"
trap 'rm -f -- "$TMP_FLASK"' EXIT INT TERM

jq \
    --arg     sqlalchemy_database_uri "$SQLALCHEMY_DATABASE_URI" \
    --arg     docroot                 "$HTDOCS_FOLDER" \
    --arg     image_folder            "$IMAGE_FOLDER" \
    --arg     migration_folder        "$MIGRATION_FOLDER" \
    --arg     secret_key              "$SECRET_KEY" \
    --arg     password_key            "$PASSWORD_KEY" \
    --argjson auth_all_views          "$AUTH_ALL_VIEWS" \
    --argjson local_auth_enable       "$LOCAL_AUTH_ENABLE" \
    --argjson cookie_secure           "$SESSION_COOKIE_SECURE" \
    --argjson admin_networks          "$ADMIN_NETWORKS" \
    --argjson oidc_enable             "$OIDC_ENABLE" \
    --argjson oidc_auto_login         "$OIDC_AUTO_LOGIN" \
    --arg     oidc_provider_name      "${INDIALLSKY_OIDC_PROVIDER_NAME:-}" \
    --arg     oidc_client_id          "${INDIALLSKY_OIDC_CLIENT_ID:-}" \
    --arg     oidc_client_secret      "${INDIALLSKY_OIDC_CLIENT_SECRET:-}" \
    --arg     oidc_discovery_endpoint "${INDIALLSKY_OIDC_DISCOVERY_ENDPOINT:-}" \
    --arg     oidc_username_claim     "${INDIALLSKY_OIDC_USERNAME_CLAIM:-preferred_username}" \
    --argjson oidc_allowed_groups     "$OIDC_ALLOWED_GROUPS" \
    --argjson oidc_admin_groups       "$OIDC_ADMIN_GROUPS" \
    '  .SQLALCHEMY_DATABASE_URI    = $sqlalchemy_database_uri
     | .INDI_ALLSKY_DOCROOT        = $docroot
     | .INDI_ALLSKY_IMAGE_FOLDER   = $image_folder
     | .MIGRATION_FOLDER           = $migration_folder
     | .SECRET_KEY                 = $secret_key
     | .PASSWORD_KEY               = $password_key
     | .INDI_ALLSKY_AUTH_ALL_VIEWS = $auth_all_views
     | .LOCAL_AUTH_ENABLE          = $local_auth_enable
     | .SESSION_COOKIE_SECURE      = $cookie_secure
     | .REMEMBER_COOKIE_SECURE     = $cookie_secure
     | .ADMIN_NETWORKS             = $admin_networks
     | .OIDC_ENABLE                = $oidc_enable
     | .OIDC_AUTO_LOGIN            = $oidc_auto_login
     | .OIDC_PROVIDER_NAME         = $oidc_provider_name
     | .OIDC_CLIENT_ID             = $oidc_client_id
     | .OIDC_CLIENT_SECRET         = $oidc_client_secret
     | .OIDC_DISCOVERY_ENDPOINT    = $oidc_discovery_endpoint
     | .OIDC_USERNAME_CLAIM        = $oidc_username_claim
     | .OIDC_ALLOWED_GROUPS        = $oidc_allowed_groups
     | .OIDC_ADMIN_GROUPS          = $oidc_admin_groups' \
    "${ALLSKY_DIRECTORY}/flask.json_template" > "$TMP_FLASK"

# Parse the rendered file before installing it, so a malformed render can
# never become the live config. jq — not upstream's json_pp, which only exists
# in these images as a transitive dependency of git's perl pull-in and would
# disappear the moment git did; jq is already a hard dependency of this script.
jq -e . "$TMP_FLASK" >/dev/null

chmod "$FLASK_CONFIG_MODE" "$TMP_FLASK"
mv -f -- "$TMP_FLASK" "${ALLSKY_ETC}/flask.json"

echo "Rendered ${ALLSKY_ETC}/flask.json (mode ${FLASK_CONFIG_MODE})"
