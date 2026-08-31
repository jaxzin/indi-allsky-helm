#!/usr/bin/env bash
# Shared helpers for the kind end-to-end scenarios.
#
# Sourced, never executed. Every caller sets its own strict mode; this file
# defines vocabulary and does no work at source time beyond reading the two
# environment knobs below.
#
# Two rules run through everything here:
#
#   * Credentials stay inside the container that owns them. Database work runs
#     through `kubectl exec` into a pod that already has the credential mounted
#     as a file, read into MYSQL_PWD by the container's own shell. Nothing ever
#     puts a password on a kubectl command line, in this script's argv, or in
#     CI output. assert_no_credential_leak is the executable form of that rule.
#   * Every wait is bounded and every failure names what broke. A poll that
#     gives up prints how long it waited and for what; a silent `|| true` is a
#     lie about coverage.
#
# Single-quoted command strings passed to `kubectl exec ... bash -c` are
# deliberate: they are expanded inside the pod, where the environment they
# reference lives, not by this shell.
#
# SC2034 is disabled for the same reason the constants exist: this file is
# sourced, so its vocabulary is consumed by the scenario scripts rather than by
# anything here. Dropping an "unused" constant would silently break whichever
# scenario reads it.
# shellcheck disable=SC2016,SC2034  # in-pod strings expand in the pod; constants are for the sourcing scripts

# Release identity. Every scenario addresses resources by label rather than by
# reconstructing the chart's naming helpers, so a change to indi-allsky.
# resourceName cannot silently make these scripts assert against nothing.
RELEASE="${RELEASE:-allsky}"
NAMESPACE="${NAMESPACE:-allsky}"

# Node-contract label keys, as the chart's values define them.
CAMERA_LABEL_KEY="indi-allsky.io/camera"
SENSORS_LABEL_KEY="indi-allsky.io/sensors"

# In-container paths, mirroring charts/indi-allsky/templates/_helpers.tpl. They
# are contract constants, not values, on both sides.
DATA_MOUNT_PATH="/var/www/html"
APP_DATA_PATH="/var/www/html/allsky"
IMAGE_PATH="/var/www/html/allsky/images"
MIGRATION_PATH="/var/www/html/allsky/.state/migrations"
BACKUP_PATH="/var/www/html/.state/backups"
OVERLAY_SENTINEL_PATH="/var/www/html/.state/config-overlay.applied"

# Container ports, likewise.
NGINX_PORT=8080
GUNICORN_PORT=8000
INDISERVER_PORT=7624
MARIADB_PORT=3306

APP_UID=10001

# The in-cluster workbench: one long-lived pod carrying the web image, the
# shared data volume and the application database credential. It exists because
# several proofs need a shell with the recovery set in front of it — the backup
# directory, the Alembic tree — and the pods that normally mount those are
# either short-lived Jobs or initContainers. It deliberately does NOT receive
# the MariaDB root Secret; keeping root out of every application and backup
# workload is one of the properties under test, not a convenience to trade away.
WORKBENCH_POD="e2e-workbench"

# Poll budgets. Named, because "60" three lines apart meaning three different
# things is how a wait ends up silently too short.
ROLLOUT_TIMEOUT_SECONDS=900
POLL_DELAY_SECONDS=5
POLL_PROGRESS_EVERY=12
FRAME_POLL_ATTEMPTS=120        # 10 minutes for the first processed frame
POD_READY_POLL_ATTEMPTS=180    # 15 minutes, covering a cold image pull
SHORT_POLL_ATTEMPTS=24         # 2 minutes for things that are already running
PORT_FORWARD_SETTLE_SECONDS=3


# --- output -----------------------------------------------------------------

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

# Every scenario runs under `set -Eeuo pipefail`, which means an unguarded
# command failure ends the script with no message at all — the exact silent
# failure these scripts exist to catch elsewhere. The ERR trap turns that into
# a located, quoted diagnostic. `set -E` makes it inherited by functions,
# subshells and command substitutions; errexit-exempt contexts (if, while, &&,
# ||) do not trigger it, so a deliberate probe still reads as a probe.
e2e_unhandled_failure() {
    local status=$?
    local source_file="${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}"
    printf 'FAIL: %s line %s: unhandled command failure (status %d), no assertion reported it: %s\n' \
        "${source_file##*/}" "${BASH_LINENO[0]:-unknown}" "$status" "$BASH_COMMAND" >&2
    exit "$status"
}
trap e2e_unhandled_failure ERR

pass() {
    printf 'PASS: %s\n' "$1"
}

note() {
    printf '  %s\n' "$1"
}

section() {
    printf '\n=== %s ===\n' "$1"
}


# --- bounded polling ---------------------------------------------------------

# retry_until <description> <attempts> <delay-seconds> <command...>
# Returns 0 as soon as the command succeeds. On exhaustion it reports the
# description and the real elapsed budget rather than returning a bare 1.
retry_until() {
    local description="$1" attempts="$2" delay="$3"
    shift 3
    local attempt
    for ((attempt = 1; attempt <= attempts; attempt++)); do
        if "$@"; then
            return 0
        fi
        if [ $((attempt % POLL_PROGRESS_EVERY)) -eq 0 ]; then
            note "still waiting for ${description} (${attempt}/${attempts} attempts, $((attempt * delay))s elapsed)"
        fi
        sleep "$delay"
    done
    printf 'gave up after %ss waiting for %s\n' "$((attempts * delay))" "$description" >&2
    return 1
}


# --- resource lookup ---------------------------------------------------------

k() {
    kubectl --namespace "$NAMESPACE" "$@"
}

# The chart labels its Deployments with the component; the StatefulSet and the
# CronJob carry only the release labels, so those are selected by instance and
# are unique within the release.
component_deployment() {  # $1 = component label value
    k get deployment \
        --selector "app.kubernetes.io/instance=${RELEASE},app.kubernetes.io/component=$1" \
        --output jsonpath='{.items[0].metadata.name}'
}

web_deployment() { component_deployment web; }
edge_deployment() { component_deployment edge; }

mariadb_statefulset() {
    k get statefulset \
        --selector "app.kubernetes.io/instance=${RELEASE}" \
        --output jsonpath='{.items[0].metadata.name}'
}

backup_cronjob() {
    k get cronjob \
        --selector "app.kubernetes.io/instance=${RELEASE}" \
        --output jsonpath='{.items[0].metadata.name}'
}

# First pod of a component, by label. Empty output means "none exists", which
# every caller treats as a distinct state rather than an error.
component_pod() {  # $1 = component label value
    k get pod \
        --selector "app.kubernetes.io/instance=${RELEASE},app.kubernetes.io/component=$1" \
        --output jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

component_pod_field() {  # $1 = component, $2 = jsonpath inside the pod
    k get pod \
        --selector "app.kubernetes.io/instance=${RELEASE},app.kubernetes.io/component=$1" \
        --output "jsonpath={.items[0].$2}" 2>/dev/null || true
}

web_service_name() {
    k get service \
        --selector "app.kubernetes.io/instance=${RELEASE},app.kubernetes.io/component=web" \
        --output jsonpath='{.items[0].metadata.name}'
}

env_configmap_name() {
    k get configmap \
        --selector "app.kubernetes.io/instance=${RELEASE}" \
        --output jsonpath='{.items[*].metadata.name}' \
        | tr ' ' '\n' | grep -E -- '-env$' | head -1
}

app_secret_name() {
    # The application Secret is the one the web Deployment names in its
    # gunicorn container's MARIADB_PASSWORD reference; reading it back from the
    # live workload keeps this independent of the naming helper.
    k get deployment "$(web_deployment)" --output \
        'jsonpath={.spec.template.spec.containers[?(@.name=="gunicorn")].env[?(@.name=="MARIADB_PASSWORD")].valueFrom.secretKeyRef.name}'
}

root_secret_name() {
    k get statefulset "$(mariadb_statefulset)" --output \
        'jsonpath={.spec.template.spec.volumes[?(@.name=="root-credentials")].secret.secretName}'
}

web_image_reference() {
    k get deployment "$(web_deployment)" --output \
        'jsonpath={.spec.template.spec.containers[?(@.name=="gunicorn")].image}'
}

overlay_expected_checksum() {
    k get configmap "$(env_configmap_name)" \
        --output jsonpath='{.data.INDIALLSKY_CONFIG_OVERLAY_SHA256}'
}

# The database endpoint as the APPLICATION sees it. Read from the env ConfigMap
# rather than from the Service object, because the headless MariaDB Service
# carries no component label and because this is the value every workload
# actually dials.
db_host() {
    k get configmap "$(env_configmap_name)" \
        --output jsonpath='{.data.INDIALLSKY_MARIADB_HOST}'
}


# --- database ----------------------------------------------------------------

# Application-account SQL, run inside the database container. The password is
# read from the projected Secret file by the container's own shell into
# MYSQL_PWD, so it never reaches argv, this script, or CI output.
db_query() {  # $1 = SQL statement
    k exec "statefulset/$(mariadb_statefulset)" --container mariadb -- \
        bash -c '
            set -Eeuo pipefail
            MYSQL_PWD="$(cat /run/secrets/app/MARIADB_PASSWORD)" \
            exec mariadb --user="$MARIADB_USER" --batch --skip-column-names \
                --execute="$1" -- "$MARIADB_DATABASE"
        ' _ "$1"
}

# Root SQL, for the operations an operator genuinely needs root for: dropping
# and recreating the target schema and re-granting the application account
# during a restore. MARIADB_ROOT_HOST is localhost, so this only works from
# inside the database container — which is the point.
db_root_query() {  # $1 = SQL statement
    k exec "statefulset/$(mariadb_statefulset)" --container mariadb -- \
        bash -c '
            set -Eeuo pipefail
            MYSQL_PWD="$(cat /run/secrets/root/MARIADB_ROOT_PASSWORD)" \
            exec mariadb --user=root --batch --skip-column-names \
                --execute="$1"
        ' _ "$1"
}

db_row_count() {  # $1 = table name
    db_query "SELECT COUNT(*) FROM \`$1\`;" | tr -d '[:space:]'
}


# --- workbench ---------------------------------------------------------------

workbench_apply() {
    local image
    image="$(web_image_reference)"
    test -n "$image" || fail "could not resolve the web image from the ${RELEASE} release"

    k apply --filename - <<POD_MANIFEST
apiVersion: v1
kind: Pod
metadata:
  name: ${WORKBENCH_POD}
  namespace: ${NAMESPACE}
  labels:
    # The same-release backup identity, so the chart's own database
    # NetworkPolicy admits this pod exactly as it admits the scheduled backup
    # Job — and so this pod doubles as the "admitted backup identity" probe.
    app.kubernetes.io/name: indi-allsky
    app.kubernetes.io/instance: ${RELEASE}
    app.kubernetes.io/component: mariadb-backup
spec:
  automountServiceAccountToken: false
  restartPolicy: Never
  terminationGracePeriodSeconds: 1
  securityContext:
    runAsNonRoot: true
    runAsUser: ${APP_UID}
    runAsGroup: ${APP_UID}
    fsGroup: ${APP_UID}
    fsGroupChangePolicy: OnRootMismatch
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: workbench
      image: ${image}
      command: ["sleep", "infinity"]
      securityContext:
        runAsNonRoot: true
        runAsUser: ${APP_UID}
        runAsGroup: ${APP_UID}
        allowPrivilegeEscalation: false
        capabilities:
          drop:
            - ALL
        seccompProfile:
          type: RuntimeDefault
      envFrom:
        - configMapRef:
            name: $(env_configmap_name)
      env:
        # The application database credential and nothing else. In particular
        # NOT the MariaDB root Secret: root isolation from application and
        # backup workloads is a property this suite asserts.
        - name: MARIADB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: $(app_secret_name)
              key: MARIADB_PASSWORD
      volumeMounts:
        - name: data
          mountPath: ${DATA_MOUNT_PATH}
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: $(k get deployment "$(web_deployment)" --output 'jsonpath={.spec.template.spec.volumes[?(@.name=="data")].persistentVolumeClaim.claimName}')
POD_MANIFEST

    retry_until "the ${WORKBENCH_POD} pod to become Ready" \
        "$POD_READY_POLL_ATTEMPTS" "$POLL_DELAY_SECONDS" \
        workbench_is_ready \
        || fail "the e2e workbench pod never became Ready"
}

workbench_is_ready() {
    [ "$(k get pod "$WORKBENCH_POD" --output 'jsonpath={.status.containerStatuses[0].ready}' 2>/dev/null)" = "true" ]
}

workbench() {  # remaining args: a bash script and its positional arguments
    k exec "$WORKBENCH_POD" --container workbench -- bash "$@"
}

# Convenience: run one bash -c string in the workbench under strict mode.
workbench_sh() {  # $1 = script, $2.. = positional arguments for it
    local script="$1"
    shift
    k exec "$WORKBENCH_POD" --container workbench -- \
        bash -c "set -Eeuo pipefail
$script" _ "$@"
}

backup_artifact_count() {  # $1 = filename prefix, e.g. pre-migrate
    workbench_sh 'find "$INDIALLSKY_BACKUP_DIR" -maxdepth 1 -type f -name "$1*.sql.gz" -print | wc -l' "$1" \
        | tr -d '[:space:]'
}

# Newest published artifact with the given prefix, or the empty string.
# `sed -n 1s//p` rather than `head -1`: head closes the pipe after one line,
# which SIGPIPEs sort, which pipefail then reports as a failure of the whole
# pipeline. sed reads the stream to the end.
newest_backup_artifact() {  # $1 = filename prefix
    workbench_sh '
        find "$INDIALLSKY_BACKUP_DIR" -maxdepth 1 -type f -name "$1*.sql.gz" -printf "%T@ %p\n" \
            | sort -rn \
            | sed -n "1s/^[^ ]* //p"
    ' "$1" | tr -d '\r\n'
}

# True when one published dump's decompressed contents contain a fixed string.
# For asserting WHAT a recovery artifact captured, not merely that it exists.
# Plain `grep`, never `grep -q`: -q exits on the first match, SIGPIPEs gzip,
# and pipefail then reports a successful search as a failed pipeline.
backup_artifact_contains() {  # $1 = artifact path in the pod, $2 = fixed string
    workbench_sh 'gzip -cd -- "$1" | grep -F -- "$2" >/dev/null' "$1" "$2"
}


# --- credential hygiene ------------------------------------------------------

# Fails if any tracked credential value appears in the given files. The values
# themselves are read into local variables and never printed, on any path —
# including the failure path, which names only the key and the file.
assert_no_credential_leak() {  # $@ = files to scan
    local app_secret root_secret key value file
    app_secret="$(app_secret_name)"
    root_secret="$(root_secret_name)"

    for file in "$@"; do
        test -f "$file" || fail "assert_no_credential_leak was given a missing file: ${file}"
    done

    for key in INDIALLSKY_FLASK_SECRET_KEY INDIALLSKY_FLASK_PASSWORD_KEY MARIADB_PASSWORD INDIALLSKY_WEB_PASS; do
        value="$(secret_value "$app_secret" "$key")"
        [ -n "$value" ] || continue
        for file in "$@"; do
            if grep -F -q -- "$value" "$file"; then
                fail "the ${key} value from Secret ${app_secret} appears in ${file}"
            fi
        done
    done

    value="$(secret_value "$root_secret" MARIADB_ROOT_PASSWORD)"
    if [ -n "$value" ]; then
        for file in "$@"; do
            if grep -F -q -- "$value" "$file"; then
                fail "the MariaDB root password appears in ${file}"
            fi
        done
    fi
}

# go-template rather than `base64 -d`, so no assumption is made about which
# base64 implementation the runner ships. A missing key yields the empty string
# rather than an error, because several keys are conditional.
secret_value() {  # $1 = secret name, $2 = key
    k get secret "$1" --output \
        "go-template={{ with index .data \"$2\" }}{{ . | base64decode }}{{ end }}" 2>/dev/null || true
}
