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

# Quoting at both PVC scalar sinks must preserve hostile multiline input as one
# scalar rather than allowing a sibling field or YAML document to be injected.
readonly MALICIOUS_SIZE=$'100Gi\ninjected: true\n---\napiVersion: v1\nkind: Secret'
helm template "${RELEASE_NAME}-quoted-size" "$CHART_DIRECTORY" \
    --values "$BASE_VALUES" \
    --set-string storage.data.size="$MALICIOUS_SIZE" \
    --set-string mariadb.persistence.size="$MALICIOUS_SIZE" \
    >"${SCRATCH_DIRECTORY}/quoted-size.yaml"
baseline_document_count="$(yq eval-all '[.] | length' "${SCRATCH_DIRECTORY}/internal.yaml")"
quoted_document_count="$(yq eval-all '[.] | length' "${SCRATCH_DIRECTORY}/quoted-size.yaml")"
quoted_shared_size="$(
    yq eval 'select(.kind == "PersistentVolumeClaim" and (.metadata.name | test("-data$")) and (.metadata.name | test("-mariadb-data$") | not)) | .spec.resources.requests.storage' \
        "${SCRATCH_DIRECTORY}/quoted-size.yaml"
)"
quoted_database_size="$(
    yq eval 'select(.kind == "PersistentVolumeClaim" and (.metadata.name | test("-mariadb-data$"))) | .spec.resources.requests.storage' \
        "${SCRATCH_DIRECTORY}/quoted-size.yaml"
)"
injected_sibling_count="$(
    yq eval-all '[select(.spec.resources.requests.injected != null)] | length' \
        "${SCRATCH_DIRECTORY}/quoted-size.yaml"
)"
test "$quoted_document_count" -eq "$baseline_document_count"
test "$quoted_shared_size" = "$MALICIOUS_SIZE"
test "$quoted_database_size" = "$MALICIOUS_SIZE"
test "$injected_sibling_count" -eq 0
printf 'direct PVC scalar injection: quoted, no sibling/document injection\n'

# The two generated recovery-set PVCs share one lifecycle policy. The internal
# StatefulSet references the standalone database claim instead of relying on a
# version-gated StatefulSet PVC-retention field.
default_shared_policy="$(
    yq eval 'select(.kind == "PersistentVolumeClaim" and (.metadata.name | test("-data$")) and (.metadata.name | test("-mariadb-data$") | not)) | .metadata.annotations."helm.sh/resource-policy"' \
        "${SCRATCH_DIRECTORY}/internal.yaml"
)"
default_database_policy="$(
    yq eval 'select(.kind == "PersistentVolumeClaim" and (.metadata.name | test("-mariadb-data$"))) | .metadata.annotations."helm.sh/resource-policy"' \
        "${SCRATCH_DIRECTORY}/internal.yaml"
)"
default_database_claim="$(
    yq eval 'select(.kind == "PersistentVolumeClaim" and (.metadata.name | test("-mariadb-data$"))) | .metadata.name' \
        "${SCRATCH_DIRECTORY}/internal.yaml"
)"
statefulset_database_claim="$(
    yq eval 'select(.kind == "StatefulSet") | .spec.template.spec.volumes[] | select(.name == "database") | .persistentVolumeClaim.claimName' \
        "${SCRATCH_DIRECTORY}/internal.yaml"
)"
unsupported_retention_field="$(
    yq eval 'select(.kind == "StatefulSet") | .spec.persistentVolumeClaimRetentionPolicy' \
        "${SCRATCH_DIRECTORY}/internal.yaml"
)"
test "$default_shared_policy" = "keep"
test "$default_database_policy" = "keep"
test "$default_database_claim" = "$statefulset_database_claim"
test "$unsupported_retention_field" = "null"

helm template "${RELEASE_NAME}-delete" "$CHART_DIRECTORY" \
    --values "$BASE_VALUES" \
    --set-string storage.retentionPolicy=Delete >"${SCRATCH_DIRECTORY}/delete.yaml"
delete_kept_count="$(
    yq eval-all '[select(.kind == "PersistentVolumeClaim" and .metadata.annotations."helm.sh/resource-policy" == "keep")] | length' \
        "${SCRATCH_DIRECTORY}/delete.yaml"
)"
delete_pvc_count="$(grep -c '^kind: PersistentVolumeClaim$' "${SCRATCH_DIRECTORY}/delete.yaml" || true)"
test "$delete_kept_count" -eq 0
test "$delete_pvc_count" -eq 2

helm template "${RELEASE_NAME}-existing" "$CHART_DIRECTORY" \
    --values "$BASE_VALUES" \
    --set-string storage.data.existingClaim=retained-data.example \
    >"${SCRATCH_DIRECTORY}/existing.yaml"
existing_pvc_count="$(grep -c '^kind: PersistentVolumeClaim$' "${SCRATCH_DIRECTORY}/existing.yaml" || true)"
existing_database_pvc_count="$(
    yq eval-all '[select(.kind == "PersistentVolumeClaim" and (.metadata.name | test("-mariadb-data$")))] | length' \
        "${SCRATCH_DIRECTORY}/existing.yaml"
)"
external_pvc_count="$(grep -c '^kind: PersistentVolumeClaim$' "${SCRATCH_DIRECTORY}/external.yaml" || true)"
external_database_pvc_count="$(
    yq eval-all '[select(.kind == "PersistentVolumeClaim" and (.metadata.name | test("-mariadb-data$")))] | length' \
        "${SCRATCH_DIRECTORY}/external.yaml"
)"
test "$existing_pvc_count" -eq 1
test "$existing_database_pvc_count" -eq 1
test "$external_pvc_count" -eq 1
test "$external_database_pvc_count" -eq 0
printf 'direct storage lifecycle: Retain/Delete symmetric, existing/external omission passed\n'

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

expect_failure \
    "invalid storage retention policy" \
    "storage.retentionPolicy must be one of: Retain, Delete" \
    --set-string storage.retentionPolicy=Archive

expect_failure \
    "non-string shared PVC size" \
    "storage.data.size must be a string" \
    --set storage.data.size=100

expect_failure \
    "empty shared PVC size" \
    "storage.data.size must be set and non-empty" \
    --set-string storage.data.size=

expect_failure \
    "non-string MariaDB PVC size" \
    "mariadb.persistence.size must be a string" \
    --set mariadb.persistence.size=8

expect_failure \
    "empty MariaDB PVC size" \
    "mariadb.persistence.size must be set and non-empty" \
    --set-string mariadb.persistence.size=

expect_failure \
    "multiline storage-class injection" \
    "storage.data.storageClassName must be a valid DNS subdomain StorageClass name" \
    --set-string storage.data.storageClassName=$'storage.example\n---\nkind: Secret'

# --- A6/A7 workload guards ---------------------------------------------------

expect_failure \
    "PriorityClass reference mode without a name" \
    "edge.priorityClass.name is required when edge.priorityClass.mode=reference" \
    --set-string edge.priorityClass.mode=reference

expect_failure \
    "PriorityClass name outside reference mode" \
    "edge.priorityClass.name must be empty when edge.priorityClass.mode=create" \
    --set-string edge.priorityClass.name=platform-owned-capture

expect_failure \
    "PriorityClass above the Kubernetes user-priority ceiling" \
    "edge.priorityClass.value must be <= 1000000000" \
    --set edge.priorityClass.value=1000000001

expect_failure \
    "bare-string host device entry" \
    "edge.devices.camera.hostPaths[0] must be an object with exactly the fields path, type and readOnly" \
    --set-string edge.devices.mode=hostpath \
    --set-json 'edge.devices.camera.hostPaths=["/dev/bus/usb"]'

expect_failure \
    "relative host device path" \
    "edge.devices.camera.hostPaths[0].path must be an absolute path with no whitespace" \
    --set-string edge.devices.mode=hostpath \
    --set-json 'edge.devices.camera.hostPaths=[{"path":"dev/bus/usb","type":"Directory","readOnly":false}]'

expect_failure \
    "unsupported host device type" \
    "edge.devices.camera.hostPaths[0].type must be one of: Directory, CharDevice" \
    --set-string edge.devices.mode=hostpath \
    --set-json 'edge.devices.camera.hostPaths=[{"path":"/dev/bus/usb","type":"Socket","readOnly":false}]'

expect_failure \
    "sensors enabled with no access mechanism" \
    "edge.sensors.enabled=true requires edge.devices.mode=hostpath or device-plugin" \
    --set edge.sensors.enabled=true

expect_failure \
    "device-plugin mode without a camera resource" \
    "edge.devices.mode=device-plugin requires edge.devices.camera.resources" \
    --set-string edge.devices.mode=device-plugin

expect_failure \
    "supplemental groups outside hostpath mode" \
    "edge.supplementalGroups must be empty unless edge.devices.mode=hostpath" \
    --set-json 'edge.supplementalGroups=[20]'

expect_failure \
    "local camera devices with an external INDI server" \
    "edge.devices.camera.hostPaths must be empty when indiserver.mode=external" \
    --set-string indiserver.mode=external \
    --set-string indiserver.external.host=indi.example.com \
    --set-string edge.devices.mode=hostpath \
    --set-json 'edge.devices.camera.hostPaths=[{"path":"/dev/bus/usb","type":"Directory","readOnly":false}]'

expect_failure \
    "capture scratch path shadowing the data volume" \
    "edge.captureTmpDir must not overlap /var/www/html" \
    --set-string edge.captureTmpDir=/var/www/html/scratch

expect_failure \
    "capture scratch path shadowing the rendered config" \
    "edge.captureTmpDir must not overlap /etc/indi-allsky" \
    --set-string edge.captureTmpDir=/etc/indi-allsky

expect_failure \
    "non-boolean NetworkPolicy toggle" \
    "networkPolicy.enabled must be a boolean" \
    --set-string networkPolicy.enabled=true

expect_failure \
    "out-of-range web Service port" \
    "web.service.port must be <= 65535" \
    --set web.service.port=70000

expect_failure \
    "enabled Ingress with no host" \
    "web.ingress.host must be set and non-empty" \
    --set web.ingress.enabled=true \
    --set-string web.ingress.host=


printf 'direct render matrix: 2 valid modes, %d invalid modes passed\n' "$case_number"
