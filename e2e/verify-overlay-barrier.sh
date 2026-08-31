#!/usr/bin/env bash
# The edge pod's exact-overlay startup barrier, exercised as a state matrix
# against the REAL edge Deployment.
#
# charts/indi-allsky/tests/db-maintenance-behavior.sh runs wait-overlay.sh
# against files in a throwaway container and covers its byte handling —
# missing, empty, malformed including the two-trailing-newline form, stale, and
# an exact match. What that cannot show is that the chart wires the script into
# an initContainer with the right environment and the right read-only mount, so
# that a sentinel state actually holds capture back inside a Kubernetes pod
# lifecycle. This does: for each state the edge pod is restarted and the
# initContainer is observed still blocking, with the diagnostic naming that
# specific state.
#
# `unreadable` is covered ONLY here, and only in-cluster. It is the one state
# that is about the filesystem rather than about bytes: the sentinel holds the
# exactly correct checksum and is denied by its mode alone. The pod is what
# makes that reachable — the workbench owns the file as uid 10001, the edge
# initContainer reads it as the same uid with every capability dropped, and
# fsGroupChangePolicy: OnRootMismatch means the kubelet does not chmod it back
# on the way in.
#
# Deliberately kept separate from the advisory-lock scenario. The barrier and
# the lock are different mechanisms with different failure modes, and a single
# script that moved both at once could not attribute a failure to either.
#
# Single-quoted in-pod command strings are expanded in the pod, not here.
# shellcheck disable=SC2016  # in-pod strings are expanded in the pod
set -Eeuo pipefail

SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=e2e/lib.sh
# shellcheck disable=SC1091  # resolved only when shellcheck is run with -x over the whole directory
source "${SCRIPT_DIRECTORY}/lib.sh"

# wait-overlay.sh logs its progress line — the one that names the current state
# — every twelfth five-second attempt, so a blocked barrier announces which
# state it is in after about a minute. Its full budget is 600s; waiting that out
# five times would add half an hour to the job for no extra information.
BARRIER_DIAGNOSTIC_ATTEMPTS=36
BARRIER_RESTORE_ATTEMPTS=60

# A syntactically valid checksum that is not this rollout's: the "stale" state
# is specifically "a well-formed checksum from a different overlay", not
# garbage.
STALE_CHECKSUM="$(printf 'previous overlay fixture' | sha256sum | cut -d' ' -f1)"

EDGE_DEPLOYMENT="$(edge_deployment)"
EXPECTED_CHECKSUM="$(overlay_expected_checksum)"
test -n "$EXPECTED_CHECKSUM" || fail "the env ConfigMap carries no INDIALLSKY_CONFIG_OVERLAY_SHA256"

workbench_apply

restore_sentinel() {
    write_sentinel "${EXPECTED_CHECKSUM}\\n"
}
cleanup() {
    # The barrier must be left releasable, or every later scenario in this job
    # inherits a wedged edge pod.
    restore_sentinel >/dev/null 2>&1 || true
    k scale "deployment/${EDGE_DEPLOYMENT}" --replicas=1 >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM HUP


# --- sentinel manipulation ---------------------------------------------------

# The sentinel lives on the shared volume. The edge pod mounts it read-only, so
# it is written from the workbench, which mounts the claim root. `printf %b`
# keeps the exact byte content — including whether there is a trailing newline,
# which is the whole difference between "match" and "malformed".
write_sentinel() {  # $1 = printf %b body, ABSENT, or UNREADABLE; $2 = body for UNREADABLE
    workbench_sh '
        sentinel="$INDIALLSKY_CONFIG_OVERLAY_APPLIED_SENTINEL"
        mkdir -p -- "$(dirname "$sentinel")"
        # The unreadable case leaves behind a file this uid owns but cannot
        # open, so every later write has to restore its own access first.
        # chmod needs ownership, not read or write permission.
        if [ -e "$sentinel" ]; then
            chmod 0600 -- "$sentinel"
        fi
        if [ "$1" = ABSENT ]; then
            rm -f -- "$sentinel"
        elif [ "$1" = UNREADABLE ]; then
            # Content that WOULD pass, denied by mode alone. That is the whole
            # point of the state: nothing about these bytes is wrong.
            printf "%s\n" "$2" > "$sentinel"
            chmod 0000 -- "$sentinel"
        else
            printf "%b" "$1" > "$sentinel"
            chmod 0600 -- "$sentinel"
        fi
    ' "$1" "${2:-}"
}

edge_pod_gone() {
    [ -z "$(component_pod edge)" ]
}

edge_pod_exists() {
    [ -n "$(component_pod edge)" ]
}

restart_edge() {
    k scale "deployment/${EDGE_DEPLOYMENT}" --replicas=0 >/dev/null
    retry_until "the edge pod to terminate" "$SHORT_POLL_ATTEMPTS" "$POLL_DELAY_SECONDS" edge_pod_gone \
        || fail "the edge pod did not terminate after scaling to zero"
    k scale "deployment/${EDGE_DEPLOYMENT}" --replicas=1 >/dev/null
    retry_until "a replacement edge pod to appear" "$SHORT_POLL_ATTEMPTS" "$POLL_DELAY_SECONDS" edge_pod_exists \
        || fail "no replacement edge pod appeared after scaling back to one"
}

barrier_is_blocking() {  # $1 = expected state word
    local pod log terminated
    pod="$(component_pod edge)"
    [ -n "$pod" ] || return 1
    log="$(k logs "$pod" --container wait-for-overlay 2>/dev/null || true)"
    printf '%s' "$log" | grep -Fq "state: $1" || return 1
    # It must still be blocking, not merely have mentioned the state on its way
    # through. A terminated initContainer would mean the gate opened.
    terminated="$(k get pod "$pod" --output \
        'jsonpath={.status.initContainerStatuses[?(@.name=="wait-for-overlay")].state.terminated.exitCode}')"
    [ -z "$terminated" ]
}

assert_state_blocks() {  # $1 = sentinel body, $2 = expected state word, $3 = optional body for UNREADABLE
    section "Sentinel state: $2"
    # Sentinel first, THEN the restart. The other order races: the replacement
    # pod would briefly see the previous, correct sentinel and could pass the
    # gate before the state under test was written.
    write_sentinel "$1" "${3:-}"
    restart_edge
    local expected="$2"
    blocking() { barrier_is_blocking "$expected"; }
    retry_until "the edge startup gate to report the '${expected}' state while still blocking" \
        "$BARRIER_DIAGNOSTIC_ATTEMPTS" "$POLL_DELAY_SECONDS" blocking \
        || {
            k logs "$(component_pod edge)" --container wait-for-overlay >&2 2>/dev/null || true
            fail "a '${expected}' sentinel did not hold the edge startup gate with a '${expected}' diagnostic"
        }
    pass "the ${expected} sentinel state keeps the edge initContainer blocking and is named in its diagnostics"
}


# --- the matrix --------------------------------------------------------------
#
# All five states wait-overlay.sh distinguishes. The two-trailing-newline form
# of `malformed` is the one variant left to
# charts/indi-allsky/tests/db-maintenance-behavior.sh, which can drive the
# script's byte handling far more cheaply than a pod restart per case.

assert_state_blocks ABSENT missing
assert_state_blocks '' empty
assert_state_blocks 'not-a-checksum\n' malformed
assert_state_blocks UNREADABLE unreadable "$EXPECTED_CHECKSUM"

# `unreadable` earns an extra assertion the other states cannot make. Its
# content is byte-for-byte the checksum this rollout expects, so the ONLY thing
# holding the gate is the file mode — and restoring just that mode, with no
# write to the file and no pod restart, must release the still-polling
# initContainer. That separates "the barrier reads the sentinel" from "the
# barrier compares the sentinel", and it is also the recovery an operator would
# perform.
workbench_sh 'chmod 0600 -- "$INDIALLSKY_CONFIG_OVERLAY_APPLIED_SENTINEL"'
retry_until "the edge Deployment to become available once the sentinel is readable again" \
    "$BARRIER_RESTORE_ATTEMPTS" "$POLL_DELAY_SECONDS" \
    k rollout status "deployment/${EDGE_DEPLOYMENT}" --timeout 10s \
    || {
        k logs "$(component_pod edge)" --container wait-for-overlay >&2 2>/dev/null || true
        fail "restoring only the sentinel's file mode did not release the edge startup gate"
    }
recovered_mode="$(workbench_sh 'stat -c %a -- "$INDIALLSKY_CONFIG_OVERLAY_APPLIED_SENTINEL"' | tr -d '[:space:]')"
test "$recovered_mode" = "600" \
    || fail "the recovered sentinel is mode ${recovered_mode}, so the gate was released by something other than the permission fix"
pass "restoring only the file mode released the gate: the bytes never changed, and the same initContainer recovered without a restart"

assert_state_blocks "${STALE_CHECKSUM}\\n" stale


section "Sentinel state: exact match"

restore_sentinel
retry_until "the edge Deployment to become available once the exact checksum is restored" \
    "$BARRIER_RESTORE_ATTEMPTS" "$POLL_DELAY_SECONDS" \
    k rollout status "deployment/${EDGE_DEPLOYMENT}" --timeout 10s \
    || fail "restoring the exact sentinel did not release the edge startup gate"

edge_pod="$(component_pod edge)"
k logs "$edge_pod" --container wait-for-overlay | grep -Fq 'edge startup gate passed' \
    || fail "the edge initContainer completed without reporting that the gate passed"
pass "an exactly matching sentinel releases the gate and the edge pod becomes available"

# Byte-exactness, restated where it is cheap: the sentinel on the volume is the
# rendered checksum and one newline, and nothing else.
sentinel_bytes="$(workbench_sh 'wc -c < "$INDIALLSKY_CONFIG_OVERLAY_APPLIED_SENTINEL"' | tr -d '[:space:]')"
test "$sentinel_bytes" -eq $(( ${#EXPECTED_CHECKSUM} + 1 )) \
    || fail "the sentinel is ${sentinel_bytes} bytes; the contract is 64 checksum characters plus exactly one newline"
pass "the sentinel is exactly ${sentinel_bytes} bytes: the checksum plus one newline"

printf '\noverlay barrier: missing/empty/malformed/unreadable/stale=blocked+diagnosed match=released permissionOnlyRecovery=released sentinelBytes=%s\n' \
    "$sentinel_bytes"
