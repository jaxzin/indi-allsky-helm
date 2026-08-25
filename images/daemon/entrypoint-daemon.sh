#!/bin/bash
# Capture daemon entrypoint. Renders the flask config, waits until the web
# pod's initContainer has finished creating the schema and the initial
# configuration, then execs the capture process.
#
# Like render-flask-config.sh, this script must never gain `set -x`.

set -o errexit
set -o nounset
set -o pipefail

ALLSKY_DIRECTORY="/home/allsky/indi-allsky"
FLASK_CONFIG="/etc/indi-allsky/flask.json"

# Readiness gate. The cap is generous because the web pod's initContainer has
# to wait for mariadb, create the schema and seed the config before this can
# succeed; past the cap the container exits non-zero and the pod's restart
# policy retries.
BOOTSTRAP_WAIT_ATTEMPTS=120
BOOTSTRAP_WAIT_INTERVAL=5
BOOTSTRAP_WAIT_LOG_EVERY=12

# Default dark-frame settings, matching darks.py's own defaults where it has
# them (--bitmax 0 means "same as container", but upstream's compose stack
# ships 16, which is the useful value for the cameras this targets).
DEFAULT_DARK_BITMAX="16"
DEFAULT_DARK_MODE="average"


# The two dark-capture booleans were the last loose ones in the repo. Every
# boolean in these images now goes through the SAME require_bool — one
# definition, in validators.sh — and rejects `True` by name. A mode switch that
# silently reinterprets a typo is a bad contract even when it cannot corrupt
# anything: DAYTIME=True previously captured --no-daytime darks without a word.
#
# Validated here, at the top, rather than at the branch that consumes them:
# they depend on nothing but the environment, and unlike the seeding guards in
# migrate.sh there is no question of whether they apply — the branch is taken
# unconditionally. So a typo fails in about a second instead of after the
# readiness gate.
# shellcheck disable=SC1091  # installed alongside this script by the Dockerfile; not resolvable at lint time
source /home/allsky/validators.sh

DARK_CAPTURE_ENABLE="$(require_bool INDIALLSKY_DARK_CAPTURE_ENABLE "${INDIALLSKY_DARK_CAPTURE_ENABLE:-false}")"
DARK_CAPTURE_DAYTIME="$(require_bool INDIALLSKY_DARK_CAPTURE_DAYTIME "${INDIALLSKY_DARK_CAPTURE_DAYTIME:-true}")"


# Fails fast (non-zero) on a missing or malformed setting, naming the variable.
/home/allsky/render-flask-config.sh

# The capture process writes images here. images/web/migrate.sh creates the
# same directory for the web pod; this repeats it because the capture pod
# mounts the same volume without running migrate.sh, and because upstream's
# `sudo chown`/mkdir entrypoint dance is gone with sudo. The effective path
# comes from the config the render step just wrote, so the default it applies
# is never restated here.
IMAGE_FOLDER="$(jq -er '.INDI_ALLSKY_IMAGE_FOLDER' "$FLASK_CONFIG")"
mkdir -p "$IMAGE_FOLDER" || {
    echo "FATAL: cannot create ${IMAGE_FOLDER} — the data volume must be writable by uid 10001 (set fsGroup: 10001)" >&2
    exit 1
}

# allsky.py / config.py resolve the application from ./app.py in the checkout —
# upstream ships no FLASK_APP — so the working directory is part of the
# contract, not a convenience.
cd "$ALLSKY_DIRECTORY"

# shellcheck disable=SC1091  # created by upstream's Dockerfile at image build time; not in this repo
source /home/allsky/venv/bin/activate


# --- wait for the web pod's migrate.sh to finish ----------------------------
#
# The probe is `config.py dumpfile`, not `config.py user_count`. user_count
# only proves the user TABLE exists (indi_allsky/config.py:1742): it returns 0
# successfully in the whole window between `flask db upgrade head` and
# `config.py bootstrap`, so it would let this daemon start against a schema
# that has no configuration row yet — and because migrate.sh runs in the web
# pod, that window is a genuine cross-pod race, not a theoretical one.
# dumpfile additionally requires a committed config row, which is exactly
# allsky.py's precondition.
#
# Output is discarded because a config dump contains third-party credentials
# decrypted; stderr is discarded per-attempt because "no configuration yet" is
# the expected state while waiting, and the bounded loop turns a persistent
# failure into a FATAL rather than an endless silent wait.
attempt=0
until ./config.py dumpfile -o /dev/null >/dev/null 2>&1; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge "$BOOTSTRAP_WAIT_ATTEMPTS" ]; then
        echo "FATAL: no indi-allsky configuration after $((BOOTSTRAP_WAIT_ATTEMPTS * BOOTSTRAP_WAIT_INTERVAL))s — check the web pod's migrate initContainer" >&2
        echo "Last probe output follows:" >&2
        # One final probe with stderr left attached, so the pod log carries the
        # actual reason (unreachable database, wrong credentials, empty schema)
        # instead of only the timeout. Its non-zero status is expected and
        # irrelevant — the loop has already decided to fail — so it is
        # swallowed to keep errexit from pre-empting the exit below.
        ./config.py dumpfile -o /dev/null >/dev/null || true
        exit 1
    fi
    if [ $((attempt % BOOTSTRAP_WAIT_LOG_EVERY)) -eq 0 ]; then
        echo "Still waiting for the initial configuration ($((attempt * BOOTSTRAP_WAIT_INTERVAL))s elapsed)"
    fi
    sleep "$BOOTSTRAP_WAIT_INTERVAL"
done
echo "Configuration is present; starting capture"


# Upstream's own knob for relocating python's scratch space — useful when the
# data volume is network-backed and /tmp is not.
if [ -n "${CAPTURE_TMPDIR:-}" ]; then
    TMPDIR="$CAPTURE_TMPDIR"
    export TMPDIR
fi

# Consumed by upstream code to detect a containerised deployment.
export INDIALLSKY_DOCKER=1


if [ "$DARK_CAPTURE_ENABLE" == "true" ]; then
    echo "*** Starting dark frame capture ***"
    # darks.py expresses daytime as a --daytime/--no-daytime flag pair, not a
    # positional (it takes exactly one positional: the mode). Build argv
    # explicitly so an unset value can never become an empty positional and
    # fail argparse — which is what upstream's start_indi_allsky.sh does.
    darks_args=(--bitmax "${INDIALLSKY_DARK_CAPTURE_BITMAX:-$DEFAULT_DARK_BITMAX}")
    if [ "$DARK_CAPTURE_DAYTIME" == "true" ]; then
        darks_args+=(--daytime)
    else
        darks_args+=(--no-daytime)
    fi
    exec ./darks.py "${darks_args[@]}" "${INDIALLSKY_DARK_CAPTURE_MODE:-$DEFAULT_DARK_MODE}"
else
    exec ./allsky.py --log stderr run
fi
