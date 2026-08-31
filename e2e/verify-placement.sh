#!/usr/bin/env bash
# Node-contract placement proof, as a SEPARATE release from the secure-default
# pipeline.
#
# Separate on purpose. The pipeline scenario proves the chart needs no node
# label, no host device and no privileged container; this one proves that when
# an operator does opt into a local hostPath camera, the edge pod lands on the
# node carrying indi-allsky.io/camera and nowhere else. Folding the two
# together would mean neither statement could be made cleanly.
#
# The cluster has TWO schedulable workers and exactly one of them is labelled.
# That is the minimum that makes the assertion mean anything: with a single
# schedulable worker the edge pod lands there whether the nodeSelector works or
# not. The fixture camera directory is created on BOTH workers, so the only
# thing that can decide placement is the label.
#
# The negative control is the other half of the proof: with the label removed
# from every node the pod must become Unschedulable for a node-selector reason,
# and must return to the labelled node when the label comes back. Without that,
# "it landed on the labelled node" is consistent with the selector doing
# nothing at all.
set -Eeuo pipefail

export RELEASE="${RELEASE:-placement}"
export NAMESPACE="${NAMESPACE:-placement}"

SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=e2e/lib.sh
# shellcheck disable=SC1091  # resolved only when shellcheck is run with -x over the whole directory
source "${SCRIPT_DIRECTORY}/lib.sh"

PLACEMENT_VALUES="${SCRIPT_DIRECTORY}/values-placement.yaml"
# Must match e2e/values-placement.yaml. Stated in both places rather than
# generated, because kubelet validates `type: Directory` against the node's
# real filesystem and a mismatch is a mount failure, not a render failure.
FIXTURE_CAMERA_DIRECTORY="/mnt/indi-allsky-e2e-camera"
MINIMUM_SCHEDULABLE_WORKERS=2
SCHEDULING_POLL_ATTEMPTS=36


section "Cluster topology"

mapfile -t workers < <(kubectl get nodes --output json \
    | jq -r '.items[]
        | select((.spec.taints // []) | map(select(.effect == "NoSchedule" or .effect == "NoExecute")) | length == 0)
        | .metadata.name')
test "${#workers[@]}" -ge "$MINIMUM_SCHEDULABLE_WORKERS" \
    || fail "this scenario needs at least ${MINIMUM_SCHEDULABLE_WORKERS} schedulable nodes; found ${#workers[@]} (${workers[*]}). A single schedulable node cannot prove label enforcement."

command -v docker >/dev/null \
    || fail "docker is required to place the fixture camera directory inside the kind node containers"

# A harmless empty directory, on EVERY schedulable node. `type: Directory` is
# checked by kubelet at mount time on whichever node is chosen, so creating it
# only on the labelled node would make a scheduling failure look like a mount
# failure — and would leave the label as a confounded variable.
for worker in "${workers[@]}"; do
    docker exec "$worker" mkdir -p "$FIXTURE_CAMERA_DIRECTORY" \
        || fail "could not create ${FIXTURE_CAMERA_DIRECTORY} inside kind node ${worker}"
done

CAMERA_NODE="${workers[0]}"
UNLABELLED_NODE="${workers[1]}"
note "schedulable nodes: ${workers[*]}"
note "labelling ONLY ${CAMERA_NODE} with ${CAMERA_LABEL_KEY}=true"

label_camera_node() {
    kubectl label node "$CAMERA_NODE" "${CAMERA_LABEL_KEY}=true" --overwrite >/dev/null
}
unlabel_all_nodes() {
    local node
    for node in "${workers[@]}"; do
        kubectl label node "$node" "${CAMERA_LABEL_KEY}-" >/dev/null 2>&1 || true
    done
}

cleanup() {
    # Leave the cluster as it was found: a stray node-contract label would make
    # any later secure-default assertion meaningless.
    unlabel_all_nodes
}
trap cleanup EXIT INT TERM HUP

unlabel_all_nodes
label_camera_node


section "Install with the explicit hostPath opt-in"

# Deliberately not --wait: this scenario asserts SCHEDULING, and the edge pod's
# overlay barrier keeps it in Init until the web pod's migration finishes.
# Waiting for readiness would spend several minutes proving something the
# pipeline scenario has already proven.
"${SCRIPT_DIRECTORY}/install-release.sh" --values "$PLACEMENT_VALUES"

edge_node() {
    component_pod_field edge 'spec.nodeName'
}

edge_scheduled() {
    [ -n "$(edge_node)" ]
}

retry_until "the edge pod to be scheduled" \
    "$SCHEDULING_POLL_ATTEMPTS" "$POLL_DELAY_SECONDS" edge_scheduled \
    || {
        k describe pod --selector "app.kubernetes.io/instance=${RELEASE},app.kubernetes.io/component=edge" >&2 || true
        fail "the edge pod was never scheduled onto any node"
    }

observed_node="$(edge_node)"
test "$observed_node" = "$CAMERA_NODE" \
    || fail "the edge pod landed on ${observed_node}; the only node carrying ${CAMERA_LABEL_KEY} is ${CAMERA_NODE}"
pass "the edge pod is on ${CAMERA_NODE}, the one labelled node, with ${UNLABELLED_NODE} schedulable and unlabelled"


section "What the hostPath opt-in actually renders, read back from the pod"

edge_pod="$(component_pod edge)"
edge_spec="$(k get pod "$edge_pod" --output json)"

selector_value="$(jq -r --arg key "$CAMERA_LABEL_KEY" '.spec.nodeSelector[$key] // ""' <<<"$edge_spec")"
test "$selector_value" = "true" \
    || fail "the edge pod carries no ${CAMERA_LABEL_KEY} nodeSelector, so its placement was not the node contract's doing"

host_path="$(jq -r '[.spec.volumes[] | select(.hostPath) | .hostPath.path] | join(",")' <<<"$edge_spec")"
test "$host_path" = "$FIXTURE_CAMERA_DIRECTORY" \
    || fail "the edge pod mounts host paths '${host_path}' rather than exactly the fixture ${FIXTURE_CAMERA_DIRECTORY}"

indiserver_privileged="$(jq -r '.spec.containers[] | select(.name == "indiserver") | .securityContext.privileged // false' <<<"$edge_spec")"
test "$indiserver_privileged" = "true" \
    || fail "the indiserver container is not privileged in hostPath camera mode; the chart documents that it is, and the pipeline scenario's contrast depends on it"

daemon_privileged="$(jq -r '.spec.containers[] | select(.name == "daemon") | .securityContext.privileged // false' <<<"$edge_spec")"
test "$daemon_privileged" = "false" \
    || fail "the daemon container is privileged; only the device-attached indiserver container may be"

runs_as_root="$(jq -r '.spec.securityContext.runAsUser' <<<"$edge_spec")"
test "$runs_as_root" = "$APP_UID" \
    || fail "the edge pod runs as uid ${runs_as_root} rather than ${APP_UID}; privileged must not have become root"
pass "hostPath mode renders the camera nodeSelector, exactly the declared host path, and one privileged-but-non-root container"


section "Negative control: no labelled node, no placement"

unlabel_all_nodes
k delete pod "$edge_pod" --wait=false

edge_unschedulable() {
    local pod reason
    pod="$(component_pod edge)"
    [ -n "$pod" ] || return 1
    [ -z "$(k get pod "$pod" --output jsonpath='{.spec.nodeName}')" ] || return 1
    reason="$(k get pod "$pod" --output \
        'jsonpath={.status.conditions[?(@.type=="PodScheduled")].reason}')"
    [ "$reason" = "Unschedulable" ]
}

retry_until "the edge pod to become Unschedulable with no labelled node" \
    "$SCHEDULING_POLL_ATTEMPTS" "$POLL_DELAY_SECONDS" edge_unschedulable \
    || {
        k describe pod --selector "app.kubernetes.io/instance=${RELEASE},app.kubernetes.io/component=edge" >&2 || true
        fail "with ${CAMERA_LABEL_KEY} removed from every node the edge pod still scheduled — the nodeSelector is not being enforced"
    }

unschedulable_message="$(k get pod "$(component_pod edge)" --output \
    'jsonpath={.status.conditions[?(@.type=="PodScheduled")].message}')"
case "$unschedulable_message" in
    *"node affinity"*|*"nodeSelector"*|*"node selector"*)
        note "scheduler reason: ${unschedulable_message}" ;;
    *)
        fail "the edge pod is Unschedulable for a reason unrelated to the node contract: ${unschedulable_message}" ;;
esac
pass "removing the label from every node makes the edge pod Unschedulable for a node-selector reason"


section "Re-labelling restores placement"

label_camera_node
retry_until "the edge pod to schedule again once the label returns" \
    "$SCHEDULING_POLL_ATTEMPTS" "$POLL_DELAY_SECONDS" edge_scheduled \
    || fail "the edge pod did not schedule after ${CAMERA_LABEL_KEY} was restored on ${CAMERA_NODE}"
observed_node="$(edge_node)"
test "$observed_node" = "$CAMERA_NODE" \
    || fail "after re-labelling, the edge pod landed on ${observed_node} rather than ${CAMERA_NODE}"
pass "the edge pod follows the label: it schedules again on ${CAMERA_NODE} and only there"

printf '\nplacement: schedulableNodes=%s labelledNodes=1 edgeNode=%s unschedulableWithoutLabel=yes privilegedContainers=indiserver-only\n' \
    "${#workers[@]}" "$CAMERA_NODE"
