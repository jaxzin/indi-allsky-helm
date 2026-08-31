#!/usr/bin/env bash
# Image and build-graph contract for the three published images.
#
#     image-contract.sh [--static-contract | --runtime-contract | --all
#                        | --build-runtime-contract]
#
# --static-contract (the default) reads the bake graph and this repository's
# own sources. It builds nothing and needs no images.
#
# --runtime-contract inspects images that ALREADY EXIST LOCALLY. It never
# builds and never pulls: every reference is resolved to an immutable image ID
# first and every container then runs with --pull=never. That is the whole
# point of the mode — evidence about "the image" is worthless if the harness
# can quietly fetch a different one from a registry, or rebuild one from
# whatever happens to be in the working tree.
#
# --all runs both, under the same no-build/no-pull rule.
#
# --build-runtime-contract is the single mode that is allowed to build. It
# bakes the current reviewed checkout into private, uniquely tagged local
# images and then runs the identical runtime sequence against those. Use it to
# produce evidence for a change that is not published yet; use --runtime-contract
# to produce evidence about an image someone else built.
#
# Statuses: 0 contract holds, 1 contract violated, 64 bad invocation,
# 70 unsupported interpreter.
#
# Single-quoted command strings are deliberate: they are evaluated inside the
# image under test, not by this shell.
# shellcheck disable=SC2016  # inner-shell strings are expanded in the container

set -o errexit
set -o nounset
set -o pipefail

EX_FAIL=1
EX_USAGE=64
EX_UNAVAILABLE=70

# Associative arrays and ${var,,} are used below; both need Bash 4.1+. macOS
# ships Bash 3.2, so contributors there need Homebrew's bash — which is what
# /usr/bin/env picks up.
if [ "${BASH_VERSINFO[0]}" -lt 4 ] \
    || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 1 ]; }; then
    printf 'FATAL: %s requires Bash 4.1 or newer (found %s)\n' \
        "${0##*/}" "${BASH_VERSION}" >&2
    exit "$EX_UNAVAILABLE"
fi

SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
IMAGES_DIRECTORY="$(cd -- "${SCRIPT_DIRECTORY}/.." && pwd)"
BAKE_FILE="${IMAGES_DIRECTORY}/docker-bake.hcl"

# The graph the chart's three published images come from: four intermediates
# that are only ever cached, and three leaves that are tagged and pushed.
INTERMEDIATE_TARGETS=(base indiserver-upstream daemon-upstream web-upstream)
PUBLISHED_TARGETS=(indiserver daemon web)
EXPECTED_TARGET_COUNT=7

OCI_SOURCE_LABEL="https://github.com/jaxzin/indi-allsky-helm"
APP_UID=10001
INDISERVER_PORT=7624
INDISERVER_STARTUP_ATTEMPTS=30
INDISERVER_STARTUP_DELAY_SECONDS=1

failure_count=0
SCRATCH_DIRECTORY=""
declare -a OWNED_IMAGE_TAGS=()

cleanup() {
    local tag
    for tag in "${OWNED_IMAGE_TAGS[@]:-}"; do
        [ -n "$tag" ] || continue
        docker image rm --force "$tag" >/dev/null 2>&1 || true
    done
    if [ -n "$SCRATCH_DIRECTORY" ]; then
        rm -rf -- "$SCRATCH_DIRECTORY"
    fi
}
trap cleanup EXIT INT TERM HUP

pass() {
    printf 'ok   %s\n' "$1"
}

violation() {
    printf 'FAIL %s\n' "$1" >&2
    failure_count=$((failure_count + 1))
}

# $1 = description, $2 = expected, $3 = actual
expect_equal() {
    if [ "$2" = "$3" ]; then
        pass "$1"
    else
        violation "$1 (expected ${2}, got ${3})"
    fi
}


# --- static contract ---------------------------------------------------------

static_contract() {
    local graph target rendered actual

    printf '\n=== static contract: build graph ===\n'
    graph="${SCRATCH_DIRECTORY}/bake.json"
    # --print resolves and validates the graph without building anything.
    docker buildx bake -f "$BAKE_FILE" --print >"$graph" 2>/dev/null

    actual="$(jq -r '.target | length' "$graph")"
    expect_equal "the bake graph has ${EXPECTED_TARGET_COUNT} targets" \
        "$EXPECTED_TARGET_COUNT" "$actual"

    for target in "${INTERMEDIATE_TARGETS[@]}"; do
        actual="$(jq -r --arg t "$target" '.target[$t].tags // [] | length' "$graph")"
        expect_equal "intermediate ${target} carries no tags" 0 "$actual"
        actual="$(jq -r --arg t "$target" '.target[$t].labels // {} | length' "$graph")"
        expect_equal "intermediate ${target} carries no OCI labels" 0 "$actual"
        actual="$(jq -r --arg t "$target" '[.target[$t].output[]? | select(.type == "cacheonly")] | length' "$graph")"
        expect_equal "intermediate ${target} is never published" 1 "$actual"
    done

    for target in "${PUBLISHED_TARGETS[@]}"; do
        actual="$(jq -r --arg t "$target" '.target[$t].labels["org.opencontainers.image.source"] // ""' "$graph")"
        expect_equal "published ${target} declares its source" "$OCI_SOURCE_LABEL" "$actual"
        actual="$(jq -r --arg t "$target" '.target[$t].tags | length' "$graph")"
        expect_equal "published ${target} carries exactly one tag" 1 "$actual"
        actual="$(jq -r --arg t "$target" '.target[$t].tags[0] | split(":")[0] | split("/") | last' "$graph")"
        expect_equal "published ${target} is tagged with its own name" \
            "indi-allsky-${target}" "$actual"
    done

    # Only the images that carry this repository's own Apache-2.0 scripts say so.
    # The indiserver overlay copies none, and NOTICE records the same split.
    for target in daemon web; do
        actual="$(jq -r --arg t "$target" '.target[$t].labels["org.opencontainers.image.licenses"] // ""' "$graph")"
        expect_equal "${target} declares its mixed licensing" \
            "GPL-3.0-only AND Apache-2.0" "$actual"
    done
    actual="$(jq -r '.target.indiserver.labels["org.opencontainers.image.licenses"] // ""' "$graph")"
    expect_equal "indiserver declares upstream-only licensing" "GPL-3.0-only" "$actual"

    printf '\n=== static contract: cache and publish helpers use their own name ===\n'
    rendered="${SCRATCH_DIRECTORY}/bake-cache.json"
    CACHE_REGISTRY=cache.example/indi-allsky CACHE_ARCH=amd64 CACHE_WRITE=true \
        docker buildx bake -f "$BAKE_FILE" --print >"$rendered" 2>/dev/null
    for target in "${INTERMEDIATE_TARGETS[@]}" "${PUBLISHED_TARGETS[@]}"; do
        # A target that passed another target's name here would silently
        # overwrite that target's cache export on every build.
        actual="$(jq -r --arg t "$target" \
            '[.target[$t]["cache-from"][]?, .target[$t]["cache-to"][]?
              | select((.ref // "") | endswith(":" + $t + "-amd64"))] | length' "$rendered")"
        expect_equal "${target} caches under its own name" 2 "$actual"
    done

    rendered="${SCRATCH_DIRECTORY}/bake-digest.json"
    PUSH_BY_DIGEST=true docker buildx bake -f "$BAKE_FILE" --print >"$rendered" 2>/dev/null
    for target in "${PUBLISHED_TARGETS[@]}"; do
        actual="$(jq -r --arg t "$target" '.target[$t].tags // [] | length' "$rendered")"
        expect_equal "${target} drops its tags for a digest push" 0 "$actual"
        actual="$(jq -r --arg t "$target" \
            '[.target[$t].output[]? | select(.["push-by-digest"] == "true")] | length' "$rendered")"
        expect_equal "${target} pushes by digest" 1 "$actual"
    done
    for target in "${INTERMEDIATE_TARGETS[@]}"; do
        actual="$(jq -r --arg t "$target" \
            '[.target[$t].output[]? | select(.["push-by-digest"] == "true")] | length' "$rendered")"
        expect_equal "intermediate ${target} is still never pushed" 0 "$actual"
    done

    printf '\n=== static contract: sources ===\n'
    if grep -Fq 'GUNICORN_BIND="127.0.0.1:8000"' "${IMAGES_DIRECTORY}/web/entrypoint-web.sh"; then
        pass "gunicorn binds loopback only"
    else
        violation "gunicorn does not bind loopback only"
    fi
    # Comments are stripped first: the entrypoint names the wildcard bind in
    # prose in order to explain why it does not use one.
    if grep -v '^[[:space:]]*#' "${IMAGES_DIRECTORY}/web/entrypoint-web.sh" \
        | grep -Eq '0\.0\.0\.0'; then
        violation "the web entrypoint still binds a wildcard address"
    else
        pass "the web entrypoint binds no wildcard address"
    fi

    local dockerfile
    for dockerfile in "${IMAGES_DIRECTORY}"/*/Dockerfile; do
        target="$(basename -- "$(dirname -- "$dockerfile")")"
        if grep -Fq 'SUDO_FORCE_REMOVE=yes apt-get purge -y sudo' "$dockerfile"; then
            pass "${target} purges the inherited sudo package"
        else
            violation "${target} does not purge the inherited sudo package"
        fi
        if grep -Eq '^USER 10001:10001$' "$dockerfile"; then
            pass "${target} ends at numeric uid/gid ${APP_UID}"
        else
            violation "${target} does not end at numeric uid/gid ${APP_UID}"
        fi
    done
}


# --- runtime contract --------------------------------------------------------

# Resolves every reference to an immutable image ID BEFORE any container runs,
# and fails if one is absent rather than fetching it. Nothing below may pull.
declare -A RESOLVED_IMAGE_IDS=()

resolve_local_images() {
    local target reference image_id
    for target in "${PUBLISHED_TARGETS[@]}"; do
        reference="$(image_reference "$target")"
        if ! image_id="$(docker image inspect --format '{{.Id}}' "$reference" 2>/dev/null)"; then
            printf 'FATAL: %s is not present locally. This mode never pulls or builds — either load it first, or use --build-runtime-contract to build the current checkout.\n' \
                "$reference" >&2
            exit "$EX_UNAVAILABLE"
        fi
        # A multi-platform index has no configuration of its own, so every
        # assertion about the image's declared user or entrypoint would read
        # empty and look like a contract violation. That is an unmet
        # precondition for this mode, not a finding: load the platform-specific
        # image, or use --build-runtime-contract, which produces one.
        if [ "$(docker image inspect --format '{{len .RootFS.Layers}}' "$image_id")" -eq 0 ]; then
            printf 'FATAL: %s resolves to a multi-platform index, not a platform image. Load the image for this platform, or use --build-runtime-contract.\n' \
                "$reference" >&2
            exit "$EX_UNAVAILABLE"
        fi
        RESOLVED_IMAGE_IDS["$target"]="$image_id"
    done

    # Three distinct images. One reference accidentally aliasing another would
    # make every per-image assertion below describe the same artifact.
    local unique
    unique="$(printf '%s\n' "${RESOLVED_IMAGE_IDS[@]}" | sort -u | wc -l | tr -d '[:space:]')"
    expect_equal "the three published references resolve to distinct images" \
        "${#PUBLISHED_TARGETS[@]}" "$unique"
}

image_reference() {  # $1 = target
    local override_name="IMAGE_${1^^}"
    override_name="${override_name//-/_}"
    printf '%s' "${!override_name:-ghcr.io/jaxzin/indi-allsky-$1:dev}"
}

# $1 = target, remaining = command. --pull=never is the load-bearing flag.
#
# A command that fails yields the sentinel below rather than aborting: one
# missing file must be reported as one violation, not silently truncate the
# rest of the contract into "no further findings".
UNAVAILABLE_SENTINEL="<unavailable>"
run_in_image() {
    local target="$1"
    shift
    docker run --rm --pull=never --entrypoint /bin/bash \
        "${RESOLVED_IMAGE_IDS[$target]}" -c "$@" 2>/dev/null \
        || printf '%s' "$UNAVAILABLE_SENTINEL"
}

runtime_contract() {
    local target actual expected

    printf '\n=== runtime contract: identity and sudo removal ===\n'
    for target in "${PUBLISHED_TARGETS[@]}"; do
        actual="$(run_in_image "$target" 'printf "%s:%s" "$(id -u)" "$(id -g)"')"
        expect_equal "${target} runs as uid/gid ${APP_UID}" "${APP_UID}:${APP_UID}" "$actual"

        actual="$(docker image inspect --format '{{.Config.User}}' "${RESOLVED_IMAGE_IDS[$target]}")"
        expect_equal "${target} declares a numeric image user" "${APP_UID}:${APP_UID}" "$actual"

        # All three: the binary, the policy, and the package. Removing only the
        # policy leaves /usr/bin/sudo setuid-root and still in the CVE class.
        actual="$(run_in_image "$target" \
            'command -v sudo >/dev/null && printf present || printf absent')"
        expect_equal "${target} has no sudo binary" absent "$actual"
        actual="$(run_in_image "$target" \
            'ls /etc/sudoers /etc/sudoers.d >/dev/null 2>&1 && printf present || printf absent')"
        expect_equal "${target} has no sudo policy" absent "$actual"
        actual="$(run_in_image "$target" \
            'dpkg-query -W -f="\${Status}" sudo 2>/dev/null | grep -q "install ok installed" && printf present || printf absent')"
        expect_equal "${target} has no sudo package" absent "$actual"
    done

    printf '\n=== runtime contract: installed scripts are this checkout byte for byte ===\n'
    local -A installed_scripts=(
        ["web:/home/allsky/entrypoint-web.sh"]="web/entrypoint-web.sh"
        ["web:/home/allsky/migrate.sh"]="web/migrate.sh"
        ["web:/home/allsky/migrate-critical.sh"]="web/migrate-critical.sh"
        ["web:/home/allsky/db-maintenance-lock.sh"]="web/db-maintenance-lock.sh"
        ["web:/home/allsky/db-connection.sh"]="web/db-connection.sh"
        ["web:/home/allsky/dump-publish.sh"]="web/dump-publish.sh"
        ["web:/home/allsky/scheduled-backup.sh"]="web/scheduled-backup.sh"
        ["web:/home/allsky/validators.sh"]="shared/validators.sh"
        ["daemon:/home/allsky/entrypoint-daemon.sh"]="daemon/entrypoint-daemon.sh"
        ["daemon:/home/allsky/wait-overlay.sh"]="daemon/wait-overlay.sh"
        ["daemon:/home/allsky/validators.sh"]="shared/validators.sh"
    )
    local key installed_path source_path expected_digest actual_digest
    for key in "${!installed_scripts[@]}"; do
        target="${key%%:*}"
        installed_path="${key#*:}"
        source_path="${IMAGES_DIRECTORY}/${installed_scripts[$key]}"
        expected_digest="$(sha256sum <"$source_path" | cut -d' ' -f1)"
        actual_digest="$(run_in_image "$target" "sha256sum < '${installed_path}'" | cut -d' ' -f1)"
        expect_equal "${target} ships this checkout's ${installed_path}" \
            "$expected_digest" "$actual_digest"
    done

    printf '\n=== runtime contract: script modes ===\n'
    for key in "${!installed_scripts[@]}"; do
        target="${key%%:*}"
        installed_path="${key#*:}"
        # Sourced files are not executable; entry points are.
        case "$installed_path" in
            */validators.sh|*/db-connection.sh|*/dump-publish.sh) expected=644 ;;
            *) expected=755 ;;
        esac
        actual="$(run_in_image "$target" "stat -c %a '${installed_path}'")"
        expect_equal "${target}'s ${installed_path} is mode ${expected}" "$expected" "$actual"
    done

    printf '\n=== runtime contract: entry points ===\n'
    expected='["/home/allsky/entrypoint-web.sh"]'
    actual="$(docker image inspect --format '{{json .Config.Entrypoint}}' "${RESOLVED_IMAGE_IDS[web]}")"
    expect_equal "web keeps its entrypoint" "$expected" "$actual"
    expected='["/home/allsky/entrypoint-daemon.sh"]'
    actual="$(docker image inspect --format '{{json .Config.Entrypoint}}' "${RESOLVED_IMAGE_IDS[daemon]}")"
    expect_equal "daemon keeps its entrypoint" "$expected" "$actual"
    # Restated from upstream rather than replaced: the overlay only removes.
    expected='["./start_indiserver.sh"]'
    actual="$(docker image inspect --format '{{json .Config.Entrypoint}}' "${RESOLVED_IMAGE_IDS[indiserver]}")"
    expect_equal "indiserver keeps upstream's driver entrypoint" "$expected" "$actual"

    printf '\n=== runtime contract: indiserver still starts its drivers ===\n'
    local container listener
    container="$(docker run --detach --rm --pull=never \
        --env "INDIALLSKY_INDI_CCD_DRIVER=indi_simulator_ccd" \
        "${RESOLVED_IMAGE_IDS[indiserver]}")"
    listener=absent
    local attempt
    for ((attempt = 1; attempt <= INDISERVER_STARTUP_ATTEMPTS; attempt++)); do
        if docker exec "$container" /bin/bash -c \
            "exec 3<>/dev/tcp/127.0.0.1/${INDISERVER_PORT}" >/dev/null 2>&1; then
            listener=present
            break
        fi
        sleep "$INDISERVER_STARTUP_DELAY_SECONDS"
    done
    expect_equal "indiserver listens on ${INDISERVER_PORT} after sudo removal" present "$listener"
    actual="$(docker exec "$container" /bin/bash -c 'printf "%s:%s" "$(id -u)" "$(id -g)"' 2>/dev/null || printf unknown)"
    expect_equal "indiserver serves as uid/gid ${APP_UID}" "${APP_UID}:${APP_UID}" "$actual"
    docker stop --timeout 10 "$container" >/dev/null 2>&1 || true
}


# --- reviewed-source build ---------------------------------------------------

build_reviewed_source() {
    local target tag suffix
    suffix="$(date -u +%Y%m%d%H%M%S)-${RANDOM}"

    printf '\n=== building the current checkout into private local images ===\n'
    for target in "${PUBLISHED_TARGETS[@]}"; do
        tag="indi-allsky-contract/${target}:${suffix}"
        if docker image inspect "$tag" >/dev/null 2>&1; then
            printf 'FATAL: the generated private tag %s already exists\n' "$tag" >&2
            exit "$EX_FAIL"
        fi
        OWNED_IMAGE_TAGS+=("$tag")
    done

    # Empty cache and push settings: a reviewed-source build must not consult or
    # populate a shared cache, and must never reach a registry.
    CACHE_REGISTRY="" CACHE_WRITE="" PUSH_BY_DIGEST="" \
        docker buildx bake -f "$BAKE_FILE" \
        --set "indiserver.tags=indi-allsky-contract/indiserver:${suffix}" \
        --set "daemon.tags=indi-allsky-contract/daemon:${suffix}" \
        --set "web.tags=indi-allsky-contract/web:${suffix}" \
        --load \
        "${PUBLISHED_TARGETS[@]}"

    for target in "${PUBLISHED_TARGETS[@]}"; do
        local override_name="IMAGE_${target^^}"
        override_name="${override_name//-/_}"
        printf -v "$override_name" '%s' "indi-allsky-contract/${target}:${suffix}"
        export "${override_name?}"
    done
}


# --- entry point -------------------------------------------------------------

mode="--static-contract"
if [ "$#" -gt 1 ]; then
    printf 'FATAL: expected at most one mode (got %d arguments)\n' "$#" >&2
    exit "$EX_USAGE"
fi
if [ "$#" -eq 1 ]; then
    mode="$1"
fi
case "$mode" in
    --static-contract|--runtime-contract|--all|--build-runtime-contract) ;;
    *)
        printf 'FATAL: unknown mode %s — expected --static-contract, --runtime-contract, --all or --build-runtime-contract\n' \
            "$mode" >&2
        exit "$EX_USAGE" ;;
esac

SCRATCH_DIRECTORY="$(mktemp -d)"

case "$mode" in
    --static-contract)
        static_contract ;;
    --runtime-contract)
        resolve_local_images
        runtime_contract ;;
    --all)
        # Still no build and no pull: the static half only reads the graph.
        static_contract
        resolve_local_images
        runtime_contract ;;
    --build-runtime-contract)
        static_contract
        build_reviewed_source
        resolve_local_images
        runtime_contract ;;
esac

printf '\n'
if [ "$failure_count" -ne 0 ]; then
    printf 'image contract (%s): %d violation(s)\n' "$mode" "$failure_count" >&2
    exit "$EX_FAIL"
fi
printf 'image contract (%s): all assertions hold\n' "$mode"
