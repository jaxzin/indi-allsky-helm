#!/usr/bin/env bash
# Installs a NetworkPolicy-enforcing CNI into the kind cluster and then PROVES
# it enforces, before any chart assertion is allowed to depend on it.
#
# Why this script exists at all: kind's default CNI, kindnet, implements pod
# networking but does not implement NetworkPolicy. Every policy this chart
# renders would therefore be accepted by the API server, look correct in
# `kubectl get networkpolicy`, and drop nothing. An e2e that asserted only
# rendering would report a green release gate for a security control that was
# not running.
#
# Calico is the choice because kind documents the disableDefaultCNI path for it
# and because it is the enforcement implementation most homelab clusters
# actually run. The manifest is pinned by upstream COMMIT SHA, not by tag —
# a tag is mutable — and its bytes are additionally checked against a recorded
# digest, so a compromised or rewritten raw endpoint fails the job rather than
# silently installing something else.
#
# The canary at the end is the part that matters. Installing a CNI proves
# nothing about enforcement; two pods, one deny-all policy, and a connection
# that succeeds before the policy and times out after it, does.
set -Eeuo pipefail

SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=e2e/lib.sh
source "${SCRIPT_DIRECTORY}/lib.sh"

# Calico v3.32.2, pinned to the commit that release tag pointed at.
CALICO_VERSION="v3.32.2"
CALICO_COMMIT="db255c554b929afd73552fd3ac81d691107a1607"
CALICO_MANIFEST_URL="https://raw.githubusercontent.com/projectcalico/calico/${CALICO_COMMIT}/manifests/calico.yaml"
CALICO_MANIFEST_SHA256="a8c828a06a87c629a282ebbc424895b77f3a030251993e41ea400a743675bb02"
CALICO_NAMESPACE="kube-system"
CALICO_ROLLOUT_TIMEOUT="600s"

# The canary's own image. Deliberately the same nginx the chart runs as its web
# sidecar, so this adds no image to the cluster that the release will not pull
# anyway, and it ships a real listener plus busybox nc for the client side.
CANARY_IMAGE="nginx:1.29-alpine"
CANARY_NAMESPACE="cni-canary"
CANARY_SERVER="canary-server"
CANARY_CLIENT="canary-client"
CANARY_PORT=80
CANARY_CONNECT_TIMEOUT_SECONDS=5
CANARY_POLICY_SETTLE_ATTEMPTS=12
CANARY_POLICY_SETTLE_DELAY_SECONDS=5

SCRATCH_DIRECTORY="$(mktemp -d)"
cleanup() {
    rm -rf -- "$SCRATCH_DIRECTORY"
}
trap cleanup EXIT INT TERM HUP


section "Installing ${CALICO_VERSION} (commit ${CALICO_COMMIT})"

manifest="${SCRATCH_DIRECTORY}/calico.yaml"
curl --silent --show-error --location --fail --output "$manifest" "$CALICO_MANIFEST_URL"

observed_sha256="$(sha256sum <"$manifest" | cut -d' ' -f1)"
if [ "$observed_sha256" != "$CALICO_MANIFEST_SHA256" ]; then
    fail "the Calico manifest at ${CALICO_MANIFEST_URL} does not match its recorded digest (expected ${CALICO_MANIFEST_SHA256}, got ${observed_sha256})"
fi
note "manifest digest verified: ${observed_sha256}"

# Server-side apply: calico.yaml carries CRDs whose schemas exceed the
# 262144-byte ceiling on the client-side last-applied-configuration annotation.
kubectl apply --server-side --force-conflicts --filename "$manifest"

kubectl --namespace "$CALICO_NAMESPACE" rollout status daemonset/calico-node \
    --timeout "$CALICO_ROLLOUT_TIMEOUT" \
    || fail "the calico-node DaemonSet did not become ready"
kubectl --namespace "$CALICO_NAMESPACE" rollout status deployment/calico-kube-controllers \
    --timeout "$CALICO_ROLLOUT_TIMEOUT" \
    || fail "calico-kube-controllers did not become ready"

kubectl wait --for=condition=Ready nodes --all --timeout "$CALICO_ROLLOUT_TIMEOUT" \
    || fail "not every node became Ready after the CNI install"

# Recorded as evidence: which images the pinned manifest actually placed.
printf 'cni images:\n'
kubectl --namespace "$CALICO_NAMESPACE" get daemonset calico-node \
    --output 'jsonpath={range .spec.template.spec.initContainers[*]}  {.name}={.image}{"\n"}{end}{range .spec.template.spec.containers[*]}  {.name}={.image}{"\n"}{end}'
pass "Calico ${CALICO_VERSION} is installed and every node is Ready"


section "Proving the CNI enforces NetworkPolicy"

kubectl create namespace "$CANARY_NAMESPACE" --dry-run=client --output yaml | kubectl apply --filename -

kubectl --namespace "$CANARY_NAMESPACE" apply --filename - <<CANARY_MANIFEST
apiVersion: v1
kind: Pod
metadata:
  name: ${CANARY_SERVER}
  labels:
    canary: server
spec:
  automountServiceAccountToken: false
  containers:
    - name: server
      image: ${CANARY_IMAGE}
      ports:
        - containerPort: ${CANARY_PORT}
---
apiVersion: v1
kind: Pod
metadata:
  name: ${CANARY_CLIENT}
  labels:
    canary: client
spec:
  automountServiceAccountToken: false
  containers:
    - name: client
      image: ${CANARY_IMAGE}
      command: ["sleep", "infinity"]
CANARY_MANIFEST

kubectl --namespace "$CANARY_NAMESPACE" wait --for=condition=Ready \
    "pod/${CANARY_SERVER}" "pod/${CANARY_CLIENT}" --timeout "$CALICO_ROLLOUT_TIMEOUT" \
    || fail "the CNI canary pods never became Ready"

server_ip="$(kubectl --namespace "$CANARY_NAMESPACE" get pod "$CANARY_SERVER" --output jsonpath='{.status.podIP}')"
test -n "$server_ip" || fail "the canary server pod has no pod IP"

canary_connects() {
    kubectl --namespace "$CANARY_NAMESPACE" exec "$CANARY_CLIENT" --container client -- \
        nc -z -w "$CANARY_CONNECT_TIMEOUT_SECONDS" "$server_ip" "$CANARY_PORT" >/dev/null 2>&1
}

canary_blocked() {
    ! canary_connects
}

# Baseline: with no policy in the namespace the connection must succeed. If it
# does not, the failure below would be indistinguishable from enforcement.
retry_until "the canary connection to succeed with no policy in place" \
    "$CANARY_POLICY_SETTLE_ATTEMPTS" "$CANARY_POLICY_SETTLE_DELAY_SECONDS" \
    canary_connects \
    || fail "the canary client could not reach the canary server even with no NetworkPolicy — pod networking itself is broken"
pass "canary baseline: pod-to-pod traffic works with no policy"

kubectl --namespace "$CANARY_NAMESPACE" apply --filename - <<'DENY_ALL'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-all-ingress
spec:
  podSelector:
    matchLabels:
      canary: server
  policyTypes:
    - Ingress
  ingress: []
DENY_ALL

retry_until "the canary connection to be denied once a deny-all policy selects the server" \
    "$CANARY_POLICY_SETTLE_ATTEMPTS" "$CANARY_POLICY_SETTLE_DELAY_SECONDS" \
    canary_blocked \
    || fail "a deny-all NetworkPolicy did NOT block pod-to-pod traffic — this CNI is not enforcing NetworkPolicy, so no policy assertion in this suite would mean anything"
pass "canary enforcement: a deny-all policy actually drops traffic"

kubectl --namespace "$CANARY_NAMESPACE" delete networkpolicy deny-all-ingress
retry_until "the canary connection to recover after the deny-all policy is removed" \
    "$CANARY_POLICY_SETTLE_ATTEMPTS" "$CANARY_POLICY_SETTLE_DELAY_SECONDS" \
    canary_connects \
    || fail "traffic did not recover after the deny-all policy was deleted — the earlier denial may not have been caused by the policy"
pass "canary reversal: removing the policy restores traffic, so the denial was the policy's doing"

kubectl delete namespace "$CANARY_NAMESPACE" --wait=false

printf '\ncni: implementation=calico version=%s manifestCommit=%s enforcement=proven\n' \
    "$CALICO_VERSION" "$CALICO_COMMIT"
