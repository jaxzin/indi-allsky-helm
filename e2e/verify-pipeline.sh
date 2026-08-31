#!/usr/bin/env bash
# The release gate's headline proof: a SECURE-DEFAULT install captures,
# processes, catalogues and serves a simulator frame.
#
# "Secure default" is not decoration here — it is half of what is being proven.
# The install runs with edge.devices.mode=none, sensors disabled, and a cluster
# in which no node carries either node-contract label. If the full
# frame -> database -> PVC -> Service path works from there, then nothing in
# that path needs a host device, a privileged container, or a labelled node,
# and the hostPath posture really is the opt-in the chart documents rather than
# a de facto requirement. e2e/verify-placement.sh proves the other half.
#
# Every posture assertion below reads the LIVE pod spec, not `helm template`.
# Template assertions already exist in charts/indi-allsky/tests; what this adds
# is that the API server admitted these pods and the kubelet ran them as
# described.
#
# Single-quoted in-pod command strings are expanded in the pod, not here.
# shellcheck disable=SC2016  # in-pod strings are expanded in the pod
set -Eeuo pipefail

SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=e2e/lib.sh
source "${SCRIPT_DIRECTORY}/lib.sh"

LOCAL_FORWARD_PORT=18080
CURL_MAX_TIME_SECONDS=20
# The `js/latest` endpoint clamps its own history window at 86400 seconds.
LATEST_HISTORY_SECONDS=86400

SCRATCH_DIRECTORY="$(mktemp -d)"
FORWARD_PID=""
cleanup() {
    if [ -n "$FORWARD_PID" ]; then
        kill "$FORWARD_PID" 2>/dev/null || true
        wait "$FORWARD_PID" 2>/dev/null || true
    fi
    rm -rf -- "$SCRATCH_DIRECTORY"
}
trap cleanup EXIT INT TERM HUP


section "Rollout"

k rollout status "statefulset/$(mariadb_statefulset)" --timeout "${ROLLOUT_TIMEOUT_SECONDS}s" \
    || fail "the MariaDB StatefulSet never became ready"
k rollout status "deployment/$(web_deployment)" --timeout "${ROLLOUT_TIMEOUT_SECONDS}s" \
    || fail "the web Deployment never became available — the migrate initContainer is the usual cause; see its logs"
k rollout status "deployment/$(edge_deployment)" --timeout "${ROLLOUT_TIMEOUT_SECONDS}s" \
    || fail "the edge Deployment never became available — the wait-for-overlay initContainer is the usual cause; see its logs"
pass "database, web and edge workloads rolled out"


section "Secure-default posture, read back from the running pods"

# 1. The cluster itself carries no node-contract label. This is what makes the
#    rest of the scenario a real proof rather than an accident of a one-node
#    cluster that happened to be labelled.
for label_key in "$CAMERA_LABEL_KEY" "$SENSORS_LABEL_KEY"; do
    labelled="$(kubectl get nodes --selector "$label_key" --output name | wc -l | tr -d ' ')"
    test "$labelled" -eq 0 \
        || fail "${labelled} node(s) carry ${label_key}; the secure-default scenario must run on a cluster with no node-contract labels at all"
done
schedulable="$(kubectl get nodes --output json \
    | jq '[.items[] | select((.spec.taints // []) | map(select(.effect == "NoSchedule" or .effect == "NoExecute")) | length == 0)] | length')"
note "schedulable nodes: ${schedulable}, node-contract labels: none"

# 2. No pod in this release requests a node, mounts a host path, is privileged,
#    can escalate privilege, or gets a service account token.
posture="${SCRATCH_DIRECTORY}/posture.json"
k get pods --selector "app.kubernetes.io/instance=${RELEASE}" --output json >"$posture"

violations="$(jq -r '
    .items[]
    | . as $pod
    | [
        (if ($pod.spec.nodeSelector // {}) | length > 0 then "\($pod.metadata.name): nodeSelector \($pod.spec.nodeSelector)" else empty end),
        (if ($pod.spec.volumes // []) | map(select(.hostPath)) | length > 0 then "\($pod.metadata.name): hostPath volume" else empty end),
        (if $pod.spec.automountServiceAccountToken != false then "\($pod.metadata.name): automountServiceAccountToken is not false" else empty end),
        ((($pod.spec.containers // []) + ($pod.spec.initContainers // []))[]
         | select(.securityContext.privileged == true)
         | "\($pod.metadata.name)/\(.name): privileged"),
        ((($pod.spec.containers // []) + ($pod.spec.initContainers // []))[]
         | select(.securityContext.allowPrivilegeEscalation != false)
         | "\($pod.metadata.name)/\(.name): allowPrivilegeEscalation is not false")
      ][]
' "$posture")"
if [ -n "$violations" ]; then
    printf '%s\n' "$violations" >&2
    fail "the secure-default install produced pods that require host access or elevated privilege"
fi

container_count="$(jq '[.items[] | (.spec.containers | length) + (.spec.initContainers // [] | length)] | add' "$posture")"
pod_count="$(jq '.items | length' "$posture")"
pass "${pod_count} pod(s) / ${container_count} container(s): no nodeSelector, no hostPath, no privileged container, no privilege escalation, no service account token"


section "Overlay barrier released against the expected checksum"

expected_checksum="$(overlay_expected_checksum)"
test -n "$expected_checksum" || fail "the env ConfigMap carries no INDIALLSKY_CONFIG_OVERLAY_SHA256"
edge_pod="$(component_pod edge)"
test -n "$edge_pod" || fail "no edge pod exists"
k logs "$edge_pod" --container wait-for-overlay >"${SCRATCH_DIRECTORY}/wait-overlay.log" 2>&1 \
    || fail "could not read the edge pod's wait-for-overlay initContainer log"
grep -Fq 'edge startup gate passed' "${SCRATCH_DIRECTORY}/wait-overlay.log" \
    || fail "the edge startup gate did not report passing; the daemon may have started without the barrier"

# The sentinel is on the shared volume; the edge daemon mounts the application
# subtree only, so this reads it through the same read-only .state mount the
# barrier itself uses.
sentinel="$(k exec "$edge_pod" --container daemon -- \
    bash -c 'cat "$INDIALLSKY_CONFIG_OVERLAY_APPLIED_SENTINEL" 2>/dev/null || true' | tr -d '\n')"
test "$sentinel" = "$expected_checksum" \
    || fail "the applied-overlay sentinel does not equal the rendered overlay checksum"
pass "the applied-overlay sentinel matches the rendered overlay checksum exactly"


section "Capture, processing and cataloguing"

image_rows_present() {
    local count
    count="$(db_row_count image 2>/dev/null || echo 0)"
    [ "${count:-0}" -gt 0 ]
}
retry_until "the capture daemon to catalogue a processed frame" \
    "$FRAME_POLL_ATTEMPTS" "$POLL_DELAY_SECONDS" \
    image_rows_present \
    || {
        k logs "deployment/$(edge_deployment)" --container daemon --tail=200 >&2 || true
        fail "no rows appeared in the image table; the simulator produced no catalogued frame"
    }
image_rows="$(db_row_count image)"
camera_rows="$(db_row_count camera)"
pass "${image_rows} image row(s) catalogued for ${camera_rows} camera(s)"

# The catalogued row must correspond to a real file on the shared volume: a
# database row alone would prove the daemon ran, not that the pipeline wrote
# anything an operator could look at. Upstream stores `filename` either
# absolute or relative to the image folder (models.py getFilesystemPath), so
# both forms are resolved the same way it resolves them.
image_filename="$(db_query 'SELECT filename FROM image ORDER BY createDate DESC LIMIT 1;' | tr -d '\r')"
test -n "$image_filename" || fail "the newest image row has an empty filename"
case "$image_filename" in
    /*) image_path="$image_filename" ;;
    *) image_path="${IMAGE_PATH}/${image_filename}" ;;
esac
k exec "$edge_pod" --container daemon -- test -f "$image_path" \
    || fail "the newest image row names ${image_path}, which does not exist on the shared volume"

k exec "$edge_pod" --container daemon -- \
    bash -c 'test -n "$(find "$1" -maxdepth 1 -type f -name "latest.*" -print -quit)"' _ "$IMAGE_PATH" \
    || fail "no latest.* file exists in ${IMAGE_PATH}; nginx has nothing to serve as the current frame"
pass "the catalogued frame and a latest.* file both exist on the shared volume"


section "Serving path"

service_name="$(web_service_name)"
k port-forward "service/${service_name}" "${LOCAL_FORWARD_PORT}:${NGINX_PORT}" >"${SCRATCH_DIRECTORY}/port-forward.log" 2>&1 &
FORWARD_PID=$!
sleep "$PORT_FORWARD_SETTLE_SECONDS"

fetch() {  # $1 = path, $2 = output file
    curl --silent --show-error --fail --max-time "$CURL_MAX_TIME_SECONDS" \
        --output "$2" --write-out '%{http_code} %{content_type}' \
        "http://127.0.0.1:${LOCAL_FORWARD_PORT}$1"
}

health="$(fetch /healthz "${SCRATCH_DIRECTORY}/healthz")" \
    || fail "the web Service did not answer /healthz through the nginx sidecar"
note "GET /healthz -> ${health}"

latest_response="$(fetch /indi-allsky/images/latest.jpg "${SCRATCH_DIRECTORY}/latest.jpg")" \
    || fail "the web Service did not serve ${IMAGE_PATH}/latest.jpg"
case "$latest_response" in
    200*image/jpeg*) ;;
    *) fail "latest.jpg came back as '${latest_response}' rather than a 200 image/jpeg" ;;
esac
test -s "${SCRATCH_DIRECTORY}/latest.jpg" || fail "latest.jpg was served with an empty body"
note "GET /indi-allsky/images/latest.jpg -> ${latest_response} ($(wc -c <"${SCRATCH_DIRECTORY}/latest.jpg" | tr -d ' ') bytes)"

# The JSON view is the application answering, not nginx serving a file, so this
# is the assertion that gunicorn is reachable THROUGH the sidecar. camera_id
# comes from the database because the view's query filters on a real camera row.
camera_id="$(db_query 'SELECT id FROM camera ORDER BY id DESC LIMIT 1;' | tr -d '[:space:]')"
test -n "$camera_id" || fail "no camera row exists, so the application never connected to the simulator"
latest_json="${SCRATCH_DIRECTORY}/latest.json"
fetch "/indi-allsky/js/latest?camera_id=${camera_id}&limit_s=${LATEST_HISTORY_SECONDS}" "$latest_json" >/dev/null \
    || fail "the application's js/latest view did not answer through the nginx sidecar"
jq -e '.latest_image.url != null' "$latest_json" >/dev/null \
    || { cat "$latest_json" >&2; fail "js/latest returned no image URL, so the application cannot see the catalogued frame"; }

# Follow the URL the application itself produced. That closes the loop: the
# daemon wrote the file, the database catalogued it, the application derived a
# URL from the row, and the nginx sidecar serves that exact URL from the
# read-only images subtree.
catalogued_url="$(jq -r '.latest_image.url' "$latest_json" | cut -d'?' -f1)"
catalogued_response="$(fetch "/indi-allsky/${catalogued_url}" "${SCRATCH_DIRECTORY}/frame.bin")" \
    || fail "the nginx sidecar did not serve /indi-allsky/${catalogued_url}, the URL the application derived from the catalogued row"
case "$catalogued_response" in
    200*image/*) ;;
    *) fail "the catalogued frame came back as '${catalogued_response}' rather than a 200 image response" ;;
esac
note "GET /indi-allsky/${catalogued_url} -> ${catalogued_response}"
pass "the Service serves nginx's own /healthz, the application's js/latest view, and the frame that view points at"

# Dot paths are 404 at any depth, so nothing can probe for the .state sibling
# that holds database dumps and the Alembic tree. 404 rather than 403 on
# purpose: a 403 would confirm the path exists.
for dot_path in /.state/backups/ /indi-allsky/images/.state /indi-allsky/.htaccess; do
    dot_status="$(curl --silent --output /dev/null --max-time "$CURL_MAX_TIME_SECONDS" \
        --write-out '%{http_code}' "http://127.0.0.1:${LOCAL_FORWARD_PORT}${dot_path}")"
    test "$dot_status" = "404" \
        || fail "${dot_path} answered ${dot_status} rather than 404"
done
pass "dot paths answer 404 at every depth the sidecar serves"

# The Service must target the nginx port only. gunicorn binds loopback, so a
# Service pointing at 8000 would have no endpoints today — and would be the
# thing that exposed an X-Forwarded-For-trusting application if that bind ever
# regressed.
service_target="$(k get service "$service_name" --output jsonpath='{.spec.ports[0].targetPort}')"
test "$service_target" = "http" \
    || fail "the web Service targets ${service_target} rather than the named nginx port"
gunicorn_ports="$(k get deployment "$(web_deployment)" --output \
    'jsonpath={.spec.template.spec.containers[?(@.name=="gunicorn")].ports}')"
test -z "$gunicorn_ports" \
    || fail "the gunicorn container advertises containerPorts (${gunicorn_ports}); it binds 127.0.0.1 only and must advertise none"
pass "the Service targets the nginx port only and gunicorn advertises no containerPort"


section "Migration side effects"

user_rows="$(db_row_count user)"
test "$user_rows" -ge 1 || fail "the user table is empty; config.py bootstrap did not run"
admin_username="$(k get configmap "$(env_configmap_name)" --output jsonpath='{.data.INDIALLSKY_WEB_USER}')"
if [ -n "$admin_username" ]; then
    seeded="$(db_query "SELECT COUNT(*) FROM \`user\` WHERE username = '${admin_username}';" | tr -d '[:space:]')"
    test "$seeded" -eq 1 \
        || fail "the configured admin account ${admin_username} was not seeded by the migration initContainer"
    note "seeded admin account present (${user_rows} account rows in total)"
fi

# A fresh database has pending schema work, so the guarded path must have taken
# a dump before touching the schema. This is the in-cluster form of the safety
# property; charts/indi-allsky/tests/db-maintenance-behavior.sh proves the
# publication primitive itself.
migrate_log="${SCRATCH_DIRECTORY}/migrate.log"
k logs "$(component_pod web)" --container migrate >"$migrate_log" 2>&1 \
    || fail "could not read the web pod's migrate initContainer log"
grep -Fq 'Migration and bootstrap complete' "$migrate_log" \
    || fail "the migrate initContainer did not reach its completion message"
assert_no_credential_leak "$migrate_log" "${SCRATCH_DIRECTORY}/wait-overlay.log"
pass "the migration initContainer completed and printed no credential value"

printf '\npipeline: images=%s cameras=%s users=%s posture=secure-default serving=ok\n' \
    "$image_rows" "$camera_rows" "$user_rows"
