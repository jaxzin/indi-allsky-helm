#!/usr/bin/env bash
# Integration proof that centralized validation aborts Helm itself and emits no
# partial manifest. helm-unittest covers every branch; this compact matrix
# protects the renderer-level property across representative failure classes.
set -Eeuo pipefail

SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIRECTORY="$(cd -- "${SCRIPT_DIRECTORY}/.." && pwd)"
BASE_VALUES="${SCRIPT_DIRECTORY}/a5-values.yaml"
EXTERNAL_VALUES="${CHART_DIRECTORY}/ci/external-values.yaml"
RELEASE_NAME="validation"

SCRATCH_DIRECTORY="$(mktemp -d)"
cleanup() {
    rm -rf -- "$SCRATCH_DIRECTORY"
}
trap cleanup EXIT INT TERM HUP

case_number=0
expect_failure() {
    local label="$1"
    local expected_error="$2"
    shift 2

    case_number=$((case_number + 1))
    local stdout_file="${SCRATCH_DIRECTORY}/case-${case_number}.stdout"
    local stderr_file="${SCRATCH_DIRECTORY}/case-${case_number}.stderr"
    local status

    set +e
    helm template "$RELEASE_NAME" "$CHART_DIRECTORY" \
        --values "$BASE_VALUES" \
        --show-only templates/configmap-env.yaml \
        "$@" >"$stdout_file" 2>"$stderr_file"
    status=$?
    set -e

    if [ "$status" -eq 0 ]; then
        printf 'FAIL: %s rendered successfully\n' "$label" >&2
        return 1
    fi
    if [ -s "$stdout_file" ]; then
        printf 'FAIL: %s emitted a partial manifest\n' "$label" >&2
        return 1
    fi
    if ! grep -Fq -- "$expected_error" "$stderr_file"; then
        printf 'FAIL: %s did not emit the expected actionable error\n' "$label" >&2
        return 1
    fi
    printf 'render validation: %s -> nonzero, no manifest\n' "$label"
}

# Prove both supported modes still render before checking the negative matrix.
helm template "${RELEASE_NAME}-internal" "$CHART_DIRECTORY" \
    --values "$BASE_VALUES" >"${SCRATCH_DIRECTORY}/internal.yaml"
test -s "${SCRATCH_DIRECTORY}/internal.yaml"

helm template "${RELEASE_NAME}-external" "$CHART_DIRECTORY" \
    --values "$EXTERNAL_VALUES" >"${SCRATCH_DIRECTORY}/external.yaml"
test -s "${SCRATCH_DIRECTORY}/external.yaml"

expect_failure \
    "missing inline Flask key" \
    "credentials.flaskSecretKey (or credentials.existingSecret) is required" \
    --set-string credentials.flaskSecretKey=

expect_failure \
    "mixed root credential modes" \
    "mariadb.rootCredentials.password must be empty when mariadb.rootCredentials.existingSecret is set" \
    --set-string mariadb.rootCredentials.existingSecret=existing-root-secret

expect_failure \
    "resolved application/root Secret collision" \
    "the resolved application and MariaDB root Secret names must be different" \
    --set-string credentials.existingSecret=validation-indi-allsky-mariadb-root \
    --set-string credentials.flaskSecretKey= \
    --set-string credentials.flaskPasswordKey= \
    --set-string credentials.mariadbPassword=

expect_failure \
    "external mode without a host" \
    "externalDatabase.host must be set and non-empty" \
    --set mariadb.enabled=false \
    --set-string mariadb.rootCredentials.password= \
    --set-string externalDatabase.host=

expect_failure \
    "zero retention" \
    "mariadb.backup.retentionDays must be >= 1" \
    --set mariadb.backup.retentionDays=0

expect_failure \
    "empty backup schedule" \
    "mariadb.backup.schedule must be non-empty when scheduled backups are enabled" \
    --set mariadb.backup.enabled=true \
    --set-string mariadb.backup.schedule=

expect_failure \
    "authentication dead end" \
    "oidc.localAuth=false requires oidc.enabled=true so a login method remains available" \
    --set oidc.localAuth=false

expect_failure \
    "credential-bearing ConfigMap path" \
    "appConfig.FILETRANSFER.PASSWORD is credential-bearing and cannot be stored in a ConfigMap" \
    --set-string appConfig.FILETRANSFER.PASSWORD=redacted-fixture

expect_failure \
    "non-list image pull secrets" \
    "image.pullSecrets must be a list of objects containing only a non-empty string name" \
    --set-json 'image.pullSecrets={"name":"registry-auth"}'

expect_failure \
    "non-string existing data claim" \
    "storage.data.existingClaim must be a string" \
    --set storage.data.existingClaim=true

expect_failure \
    "database query-field injection" \
    "externalDatabase.charset may contain only letters, digits, and underscore" \
    --set-string 'externalDatabase.charset=utf8mb4&ssl_verify_identity=false'

expect_failure \
    "invalid image pull policy" \
    "image.pullPolicy must be one of: Always, IfNotPresent, Never" \
    --set-string image.pullPolicy=Sometimes

printf 'direct render matrix: 2 valid modes, %d invalid modes passed\n' "$case_number"
