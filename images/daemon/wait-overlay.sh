#!/bin/bash
# Exact-overlay startup barrier for the edge pod.
#
# The chart runs this as the edge pod's first initContainer. It blocks until
# the applied-overlay checksum sentinel published by the web pod's migration
# path equals the checksum of the overlay THIS rollout expects, then exits 0
# so the daemon container can start.
#
# WHY EXACT EQUALITY, NOT "THE FILE EXISTS"
#
# The sentinel survives across rollouts. A previous rollout's checksum is
# present and readable the whole time a new one is migrating, so an
# existence-only or "readable" gate would release capture against the previous
# configuration — precisely the failure this barrier exists to prevent.
#
# WHY THIS IS A SEPARATE, SHIPPED SCRIPT
#
# It is the only place the sentinel's byte format is interpreted, and its
# failure modes (missing / empty / malformed / stale / timeout) are behaviour,
# not manifest content. As a file in the image it is shellcheck-linted with
# every other script here and can be exercised directly against real files;
# inlined into the Deployment's args it would be neither.
#
# WHAT THIS IS NOT
#
# It is not the database readiness gate. entrypoint-daemon.sh keeps its own
# bounded `config.py dumpfile` loop for that, and it is not a rollout epoch:
# an image- or schema-only upgrade whose overlay bytes are unchanged passes
# this barrier immediately, by design. Issue #9 owns that ordering.

set -o errexit
set -o nounset
set -o pipefail

# Fixed internal timing, matching entrypoint-daemon.sh's own readiness budget
# (10 minutes). Deliberately not public chart values: this is a bounded retry
# inside a container the kubelet already restarts, and the kubelet's backoff —
# not a chart knob — is the authoritative retry policy.
WAIT_ATTEMPTS=120
WAIT_INTERVAL=5
WAIT_LOG_EVERY=12

# The chart's checksum contract: exactly 64 lowercase hex characters, and the
# sentinel holds exactly that plus one trailing newline.
CHECKSUM_PATTERN='^[0-9a-f]{64}$'

# shellcheck disable=SC1091  # installed alongside this script by the Dockerfile; not resolvable at lint time
source /home/allsky/validators.sh

EXPECTED_CHECKSUM="$(require_nonempty INDIALLSKY_CONFIG_OVERLAY_SHA256 "${INDIALLSKY_CONFIG_OVERLAY_SHA256:-}")"
SENTINEL_PATH="$(require_nonempty INDIALLSKY_CONFIG_OVERLAY_APPLIED_SENTINEL "${INDIALLSKY_CONFIG_OVERLAY_APPLIED_SENTINEL:-}")"

if ! [[ "$EXPECTED_CHECKSUM" =~ $CHECKSUM_PATTERN ]]; then
    echo "FATAL: INDIALLSKY_CONFIG_OVERLAY_SHA256 must be 64 lowercase hex characters (got ${#EXPECTED_CHECKSUM} bytes)" >&2
    exit 1
fi


# Classifies the sentinel into one distinct state per cause, so the timeout
# message says which of five different problems the operator is looking at.
# Always succeeds — the caller's loop decides what a state means.
#
# The read preserves bytes exactly. `$(cat file)` strips ALL trailing newlines,
# which would silently accept a sentinel ending in two of them; the contract is
# "remove at most one".
sentinel_state() {
    local raw value
    if [ ! -e "$SENTINEL_PATH" ]; then
        printf 'missing'
        return 0
    fi
    if [ ! -f "$SENTINEL_PATH" ] || [ ! -r "$SENTINEL_PATH" ]; then
        printf 'unreadable'
        return 0
    fi
    raw="$(cat -- "$SENTINEL_PATH"; printf 'x')" || { printf 'unreadable'; return 0; }
    raw="${raw%x}"
    if [ -z "$raw" ]; then
        printf 'empty'
        return 0
    fi
    value="${raw%$'\n'}"
    if ! [[ "$value" =~ $CHECKSUM_PATTERN ]]; then
        printf 'malformed'
        return 0
    fi
    if [ "$value" != "$EXPECTED_CHECKSUM" ]; then
        printf 'stale'
        return 0
    fi
    printf 'match'
}


attempt=0
while :; do
    state="$(sentinel_state)"
    if [ "$state" == "match" ]; then
        echo "Applied-overlay checksum sentinel matches; edge startup gate passed"
        exit 0
    fi

    attempt=$((attempt + 1))
    if [ "$attempt" -ge "$WAIT_ATTEMPTS" ]; then
        # Non-zero rather than an endless loop: an initContainer that never
        # exits is invisible to every restart and alerting mechanism the
        # cluster has, while a failing one is a CrashLoopBackOff someone sees.
        echo "FATAL: applied-overlay checksum sentinel did not match after $((WAIT_ATTEMPTS * WAIT_INTERVAL))s (last state: ${state}) — check the web pod's migrate initContainer" >&2
        exit 1
    fi
    if [ $((attempt % WAIT_LOG_EVERY)) -eq 0 ]; then
        echo "Still waiting for the applied-overlay checksum sentinel ($((attempt * WAIT_INTERVAL))s elapsed, state: ${state})"
    fi
    sleep "$WAIT_INTERVAL"
done
