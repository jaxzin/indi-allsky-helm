#!/usr/bin/env bash
# The edge pod's exact-overlay startup barrier, exercised as a state matrix
# against the REAL edge Deployment.
#
# charts/indi-allsky/tests/db-maintenance-behavior.sh already runs
# wait-overlay.sh against files in a throwaway container and proves it
# classifies each sentinel state. What that cannot show is that the chart wires
# the script into an initContainer with the right environment and the right
# read-only mount, so that a sentinel state actually holds capture back inside
# a Kubernetes pod lifecycle. This does: for each state the edge pod is
# restarted and the initContainer is observed still blocking, with the
# diagnostic naming that specific state.
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
write_sentinel() {  # $1 = printf %b body, or the literal ABSENT
    workbench_sh '
        sentinel="$INDIALLSKY_CONFIG_OVERLAY_APPLIED_SENTINEL"
        mkdir -p -- "$(dirname "$sentinel")"
        if [ "$1" = ABSENT ]; then
            rm -f -- "$sentinel"
        else
            printf "%b" "$1" > "$sentinel"
            chmod 0600 "$sentinel"
        fi
    ' "$1"
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

assert_state_blocks() {  # $1 = sentinel body, $2 = expected state word
    section "Sentinel state: $2"
    # Sentinel first, THEN the restart. The other order races: the replacement
    # pod would briefly see the previous, correct sentinel and could pass the
    # gate before the state under test was written.
    write_sentinel "$1"
    restart_edge
    local expected="$2"
    blocking() { barrier_is_blocking "$expected"; }
    retry_until "the edge startup gate to report the '${expected}' state while still blocking" \
        "$BARRIER_DIAGNOSTIC_ATTEMPTS" "$POLL_DELAY_SECONDS" blocking \
        || {
            k logs "$(component_pod edge)" --container wait-for-overlay >&2 2>/dev/null || true
            fail "a '${expected}' sentinel did not hold the edge startup gate with a '${expected}' diagnostic"
        }
    pass "a ${expected} sentinel keeps the edge initContainer blocking and names the state"
}


# --- the matrix --------------------------------------------------------------
#
# `unreadable` is the one documented state not exercised here: producing it
# needs a mode or ownership the workbench cannot set on a volume it shares with
# the pod under test. It is covered against real files by
# charts/indi-allsky/tests/db-maintenance-behavior.sh, along with the
# two-trailing-newline form of `malformed`.

assert_state_blocks ABSENT missing
assert_state_blocks '' empty
assert_state_blocks 'not-a-checksum\n' malformed
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

printf '\noverlay barrier: missing/empty/malformed/stale=blocked+diagnosed match=released sentinelBytes=%s\n' \
    "$sentinel_bytes"
