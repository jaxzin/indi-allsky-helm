#!/usr/bin/env bash
# Runtime proof that the chart's NetworkPolicies actually move packets around,
# on a cluster whose CNI e2e/install-cni.sh has already shown enforces policy.
#
# The unit suite in charts/indi-allsky/tests/networkpolicy_test.yaml asserts
# what the objects say. That is necessary and not sufficient: a policy that
# selects the wrong pods, or a cluster that ignores policy entirely, passes
# every template assertion. Everything below is a connection attempt from one
# pod to another.
#
# The probes distinguish DROPPED from REFUSED, which matters more than it
# looks. gunicorn binds 127.0.0.1 only, so a probe of :8000 fails whether or
# not a policy exists — the interesting question is WHY it failed. A policy
# drop times out; a closed port refuses immediately. Asserting the specific
# failure mode, and then removing the policy and asserting the other one, is
# what separates "the policy is enforcing" from "the port happened to be shut".
#
# Single-quoted in-pod command strings are expanded in the pod, not here.
# shellcheck disable=SC2016  # in-pod strings are expanded in the pod
set -Eeuo pipefail

SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=e2e/lib.sh
# shellcheck disable=SC1091  # resolved only when shellcheck is run with -x over the whole directory
source "${SCRIPT_DIRECTORY}/lib.sh"

UNLABELLED_PROBE="np-probe-unlabelled"
OTHER_RELEASE_PROBE="np-probe-other-release"
OTHER_RELEASE_NAME="some-other-release"

# `timeout` sends TERM and reports 124 on expiry; bash reports 1 with
# "Connection refused" when the peer answers with a RST.
TCP_PROBE_TIMEOUT_SECONDS=6
STATUS_CONNECTED=0
STATUS_REFUSED=1
STATUS_TIMED_OUT=124

# Policy changes are programmed asynchronously by the CNI, so every expectation
# is polled rather than sampled once.
POLICY_SETTLE_ATTEMPTS=15
POLICY_SETTLE_DELAY_SECONDS=4

SCRATCH_DIRECTORY="$(mktemp -d)"
cleanup() {
    k delete pod "$UNLABELLED_PROBE" "$OTHER_RELEASE_PROBE" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    rm -rf -- "$SCRATCH_DIRECTORY"
}
trap cleanup EXIT INT TERM HUP


# --- probe fixtures ----------------------------------------------------------

web_pod="$(component_pod web)"
edge_pod="$(component_pod edge)"
test -n "$web_pod" || fail "no web pod exists"
test -n "$edge_pod" || fail "no edge pod exists"

probe_image="$(web_image_reference)"
# Pinned to the node the web pod already runs on. Not a scheduling statement:
# these probes need bash and GNU timeout, which means the (large) web image,
# and co-locating them with a pod that already has it avoids a second pull. The
# database pod is free to be elsewhere, so the cross-node path is still
# exercised by the :3306 probes.
probe_node="$(k get pod "$web_pod" --output jsonpath='{.spec.nodeName}')"

create_probe() {  # $1 = pod name, $2 = extra labels as YAML lines (may be empty)
    k apply --filename - <<PROBE
apiVersion: v1
kind: Pod
metadata:
  name: $1
  namespace: ${NAMESPACE}
  labels:
    e2e-role: network-probe
$2
spec:
  automountServiceAccountToken: false
  restartPolicy: Never
  terminationGracePeriodSeconds: 1
  nodeName: ${probe_node}
  securityContext:
    runAsNonRoot: true
    runAsUser: ${APP_UID}
    runAsGroup: ${APP_UID}
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: probe
      image: ${probe_image}
      command: ["sleep", "infinity"]
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop:
            - ALL
PROBE
}

section "Probe fixtures"

create_probe "$UNLABELLED_PROBE" ""
# Same chart, same component name, DIFFERENT release: the database policy
# selects on the release instance too, so this pod proves the rule is not
# satisfied by the chart labels alone.
create_probe "$OTHER_RELEASE_PROBE" "    app.kubernetes.io/name: indi-allsky
    app.kubernetes.io/instance: ${OTHER_RELEASE_NAME}
    app.kubernetes.io/component: web"

k wait --for=condition=Ready "pod/${UNLABELLED_PROBE}" "pod/${OTHER_RELEASE_PROBE}" \
    --timeout "${ROLLOUT_TIMEOUT_SECONDS}s" \
    || fail "the network probe pods never became Ready"

# The same-release backup identity, which the database policy must admit.
workbench_apply
pass "probes ready: unlabelled, other-release, and the same-release backup identity"


# --- probe primitive ---------------------------------------------------------

probe_status() {  # $1 = pod, $2 = container, $3 = host, $4 = port
    local status=0
    k exec "$1" --container "$2" -- \
        timeout "$TCP_PROBE_TIMEOUT_SECONDS" \
        bash -c 'exec 3<>/dev/tcp/"$1"/"$2"' _ "$3" "$4" \
        >/dev/null 2>&1 || status=$?
    printf '%s' "$status"
}

status_name() {  # $1 = numeric status
    case "$1" in
        "$STATUS_CONNECTED") printf 'connected' ;;
        "$STATUS_REFUSED") printf 'refused' ;;
        "$STATUS_TIMED_OUT") printf 'dropped (timed out)' ;;
        *) printf 'unexpected status %s' "$1" ;;
    esac
}

expect_status() {  # $1 = description, $2 = expected, $3 = pod, $4 = container, $5 = host, $6 = port
    local description="$1" expected="$2"
    shift 2
    local observed
    matches() {
        observed="$(probe_status "$@")"
        [ "$observed" = "$expected" ]
    }
    if retry_until "$description" "$POLICY_SETTLE_ATTEMPTS" "$POLICY_SETTLE_DELAY_SECONDS" matches "$@"; then
        note "$(printf '%-58s %s' "$description" "$(status_name "$expected")")"
        return 0
    fi
    fail "${description}: expected $(status_name "$expected"), observed $(status_name "$observed")"
}

# Capture a chart-managed policy so it can be removed for a negative control
# and put back byte-identically. Server-assigned fields are stripped so the
# re-apply is a create rather than a rejected update.
capture_policy() {  # $1 = policy name -> path of the captured manifest
    local name="$1" file="${SCRATCH_DIRECTORY}/policy-${1}.json"
    k get networkpolicy "$name" --output json \
        | jq 'del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp,
                  .metadata.generation, .metadata.managedFields, .status)' >"$file"
    printf '%s' "$file"
}

web_policy="$(k get networkpolicy --selector "app.kubernetes.io/instance=${RELEASE},app.kubernetes.io/component=web" --output jsonpath='{.items[0].metadata.name}')"
edge_policy="$(k get networkpolicy --selector "app.kubernetes.io/instance=${RELEASE},app.kubernetes.io/component=edge" --output jsonpath='{.items[0].metadata.name}')"
mariadb_policy="$(k get networkpolicy --selector "app.kubernetes.io/instance=${RELEASE},app.kubernetes.io/component=mariadb" --output jsonpath='{.items[0].metadata.name}')"
for policy_name in "$web_policy" "$edge_policy" "$mariadb_policy"; do
    test -n "$policy_name" || fail "the release did not render all three ingress policies (web, edge, mariadb)"
done

web_pod_ip="$(k get pod "$web_pod" --output jsonpath='{.status.podIP}')"
edge_pod_ip="$(k get pod "$edge_pod" --output jsonpath='{.status.podIP}')"
database_host="$(db_host)"


section "Web pod: the nginx port is the only one admitted"

expect_status "nginx :${NGINX_PORT} from an unlabelled pod" \
    "$STATUS_CONNECTED" "$UNLABELLED_PROBE" probe "$web_pod_ip" "$NGINX_PORT"
expect_status "gunicorn :${GUNICORN_PORT} from an unlabelled pod" \
    "$STATUS_TIMED_OUT" "$UNLABELLED_PROBE" probe "$web_pod_ip" "$GUNICORN_PORT"

# Negative control. With the policy gone the same probe must be REFUSED, not
# connected: that is gunicorn's 127.0.0.1 bind answering, and it proves the
# timeout above was the policy dropping packets rather than the port being
# shut. Both layers of the documented defence are therefore observed
# separately.
web_policy_backup="$(capture_policy "$web_policy")"
k delete networkpolicy "$web_policy"
expect_status "gunicorn :${GUNICORN_PORT} with the web policy removed" \
    "$STATUS_REFUSED" "$UNLABELLED_PROBE" probe "$web_pod_ip" "$GUNICORN_PORT"
k apply --filename "$web_policy_backup"
expect_status "gunicorn :${GUNICORN_PORT} once the web policy is restored" \
    "$STATUS_TIMED_OUT" "$UNLABELLED_PROBE" probe "$web_pod_ip" "$GUNICORN_PORT"
pass "the web policy admits :${NGINX_PORT} and drops :${GUNICORN_PORT}, which the loopback bind independently refuses"


section "Edge pod: no ingress at all"

# indiserver genuinely listens on this port inside the edge pod, so the
# positive and negative controls here are unambiguous.
expect_status "indiserver :${INDISERVER_PORT} from an unlabelled pod" \
    "$STATUS_TIMED_OUT" "$UNLABELLED_PROBE" probe "$edge_pod_ip" "$INDISERVER_PORT"

edge_policy_backup="$(capture_policy "$edge_policy")"
k delete networkpolicy "$edge_policy"
expect_status "indiserver :${INDISERVER_PORT} with the edge policy removed" \
    "$STATUS_CONNECTED" "$UNLABELLED_PROBE" probe "$edge_pod_ip" "$INDISERVER_PORT"
k apply --filename "$edge_policy_backup"
expect_status "indiserver :${INDISERVER_PORT} once the edge policy is restored" \
    "$STATUS_TIMED_OUT" "$UNLABELLED_PROBE" probe "$edge_pod_ip" "$INDISERVER_PORT"
pass "the edge policy denies ingress to a port that is demonstrably open without it"

# The other half of the same question, raised as a risk in issue #36: a
# deny-all ingress policy could equally deny the KUBELET's TCP probes against
# indiserver, which would show up as an edge pod that never becomes Ready
# rather than as a security failure. It does not — the kubelet dials from the
# node's own network namespace, which the CNI admits — and the proof is that
# the container is Ready and has never been restarted while the policy that
# just dropped an identical connection from a pod is in force.
indiserver_ready="$(k get pod "$edge_pod" --output \
    'jsonpath={.status.containerStatuses[?(@.name=="indiserver")].ready}')"
indiserver_restarts="$(k get pod "$edge_pod" --output \
    'jsonpath={.status.containerStatuses[?(@.name=="indiserver")].restartCount}')"
test "$indiserver_ready" = "true" \
    || fail "the indiserver container is not Ready under the edge deny-all policy; its TCP probes are being dropped along with pod traffic"
test "${indiserver_restarts:-0}" -eq 0 \
    || fail "the indiserver container has restarted ${indiserver_restarts} time(s) under the edge deny-all policy; its liveness probe is being dropped"
pass "the kubelet's own TCP probes still reach indiserver: Ready, ${indiserver_restarts} restarts, under the same policy that drops pod traffic"


section "Internal database: same-release clients only"

expect_status "mariadb :${MARIADB_PORT} from this release's web pod" \
    "$STATUS_CONNECTED" "$web_pod" gunicorn "$database_host" "$MARIADB_PORT"
expect_status "mariadb :${MARIADB_PORT} from this release's edge pod" \
    "$STATUS_CONNECTED" "$edge_pod" daemon "$database_host" "$MARIADB_PORT"
expect_status "mariadb :${MARIADB_PORT} from this release's backup identity" \
    "$STATUS_CONNECTED" "$WORKBENCH_POD" workbench "$database_host" "$MARIADB_PORT"
expect_status "mariadb :${MARIADB_PORT} from an unlabelled pod" \
    "$STATUS_TIMED_OUT" "$UNLABELLED_PROBE" probe "$database_host" "$MARIADB_PORT"
expect_status "mariadb :${MARIADB_PORT} from another release's web component" \
    "$STATUS_TIMED_OUT" "$OTHER_RELEASE_PROBE" probe "$database_host" "$MARIADB_PORT"
pass "the database admits web, edge and backup from THIS release and nothing else in the namespace"


section "Egress is deliberately unrestricted"

egress_policies="$(k get networkpolicy --selector "app.kubernetes.io/instance=${RELEASE}" --output json \
    | jq -r '[.items[] | select(.spec.policyTypes // [] | index("Egress")) | .metadata.name] | join(", ")')"
test -z "$egress_policies" \
    || fail "the release rendered egress policies (${egress_policies}); the chart documents that it renders none, because a partial egress policy would break the external database, OIDC, MQTT and upload destinations it supports"
pass "no egress policy is rendered, matching the documented deliberate omission"

printf '\nnetwork policy: webIngress=8080-only gunicorn=dropped+refused edgeIngress=denied database=same-release-only egress=unrestricted\n'
