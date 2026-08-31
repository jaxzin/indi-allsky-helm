#!/usr/bin/env bash
# Negative control for the unit suites.
#
# A passing test suite proves the chart renders what the tests expect; it does
# not prove the tests would notice if the chart stopped doing so. Each case
# below copies the chart, breaks one contract, and requires the suites to go
# red — and to go red in the specific test that owns that contract, so a
# mutation cannot be "caught" by an unrelated assertion.
#
# Every mutation here corresponds to a security or safety property from #5, #6,
# #16 or #22. If one of them stops failing, an assertion has been weakened.
#
# The sed scripts are single-quoted on purpose: they contain Go template
# variables like {{ $canonical }} that must reach sed literally, not be expanded
# by this shell.
# shellcheck disable=SC2016  # sed scripts carry literal Go template variables
set -Eeuo pipefail

SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIRECTORY="$(cd -- "${SCRIPT_DIRECTORY}/.." && pwd)"
CHART_NAME="$(basename -- "$CHART_DIRECTORY")"

SCRATCH_DIRECTORY="$(mktemp -d)"
cleanup() {
    rm -rf -- "$SCRATCH_DIRECTORY"
}
trap cleanup EXIT INT TERM HUP

case_number=0

# $1 = label, $2 = test name that must fail, $3 = relative file, $4 = sed script
expect_mutation_detected() {
    local label="$1" owning_test="$2" relative_file="$3" sed_script="$4"
    local chart_copy output_file status

    case_number=$((case_number + 1))
    chart_copy="${SCRATCH_DIRECTORY}/case-${case_number}/${CHART_NAME}"
    output_file="${SCRATCH_DIRECTORY}/case-${case_number}.log"

    mkdir -p -- "$(dirname -- "$chart_copy")"
    cp -R -- "$CHART_DIRECTORY" "$chart_copy"

    # A mutation that changes nothing would make the case vacuous: the suite
    # would fail for some unrelated reason, or not at all, and either way the
    # control would prove nothing.
    if ! sed -i.bak -e "$sed_script" -- "${chart_copy}/${relative_file}"; then
        printf 'FAIL: %s could not apply its mutation\n' "$label" >&2
        return 1
    fi
    if cmp -s -- "${chart_copy}/${relative_file}" "${chart_copy}/${relative_file}.bak"; then
        printf 'FAIL: %s mutation matched nothing — the control is vacuous\n' "$label" >&2
        return 1
    fi
    rm -f -- "${chart_copy}/${relative_file}.bak"

    set +e
    helm unittest "$chart_copy" >"$output_file" 2>&1
    status=$?
    set -e

    if [ "$status" -eq 0 ]; then
        printf 'FAIL: %s was not detected — the suites still pass\n' "$label" >&2
        return 1
    fi
    if ! grep -Fq -- "$owning_test" "$output_file"; then
        printf 'FAIL: %s went red, but not in the test that owns the contract (%s)\n' \
            "$label" "$owning_test" >&2
        return 1
    fi
    printf 'mutation control: %s -> detected by "%s"\n' "$label" "$owning_test"
}

# Baseline. A suite that is already red would make every case below meaningless.
helm unittest "$CHART_DIRECTORY" >"${SCRATCH_DIRECTORY}/baseline.log" 2>&1 || {
    printf 'FAIL: the unit suites are red before any mutation\n' >&2
    tail -n 40 "${SCRATCH_DIRECTORY}/baseline.log" >&2
    exit 1
}
printf 'mutation control: baseline suites pass\n'

# --- #16: one-writer web topology -------------------------------------------

expect_mutation_detected \
    "web replicas increased" \
    "renders exactly one replica that is replaced, never surged" \
    templates/web-deployment.yaml \
    's/^  replicas: 1$/  replicas: 2/'

expect_mutation_detected \
    "web rollout allowed to surge" \
    "renders exactly one replica that is replaced, never surged" \
    templates/web-deployment.yaml \
    's/^    type: Recreate$/    type: RollingUpdate/'

expect_mutation_detected \
    "edge replicas increased" \
    "renders one replica that is replaced, never surged" \
    templates/edge-deployment.yaml \
    's/^  replicas: 1$/  replicas: 2/'

# --- #5: Secret projection ---------------------------------------------------

expect_mutation_detected \
    "blanket Secret envFrom on gunicorn" \
    "never projects the application Secret through a blanket envFrom" \
    templates/web-deployment.yaml \
    's|^          envFrom:$|          envFrom:\n            - secretRef:\n                name: {{ include "indi-allsky.envSecretName" . }}|'

expect_mutation_detected \
    "MariaDB root Secret referenced by the web pod" \
    "mounts exactly the volumes the web pod needs and no Secret volume" \
    templates/web-deployment.yaml \
    's|^      volumes:$|      volumes:\n        - name: root-credentials\n          secret:\n            secretName: {{ include "indi-allsky.mariadbRootSecretName" . }}|'

expect_mutation_detected \
    "admin bootstrap password handed to gunicorn" \
    "adds the OIDC and admin-seed keys only to the container that uses them" \
    templates/web-deployment.yaml \
    's|(dict "ctx" . "oidc" true "adminSeed" false)|(dict "ctx" . "oidc" true "adminSeed" true)|'

expect_mutation_detected \
    "OIDC client secret handed to the edge daemon" \
    "gives the daemon its database keys and nothing else" \
    templates/edge-deployment.yaml \
    's|(dict "ctx" . "oidc" false "adminSeed" false)|(dict "ctx" . "oidc" true "adminSeed" false)|'

# --- #5: minimum PVC visibility and the serving path -------------------------

expect_mutation_detected \
    "whole data volume mounted into nginx" \
    "gives each container the least data-volume visibility it can work with" \
    templates/web-deployment.yaml \
    's|^              subPath: {{ \$imageSubPath }}$||'

expect_mutation_detected \
    "dot-path deny removed from the nginx config" \
    "returns 404 for every dot path, including the state sibling" \
    templates/configmap-nginx.yaml \
    's|^            location ~ /\\\. {$|            location ~ /never-matches {|'

expect_mutation_detected \
    "gunicorn reachable off-loopback through the proxy" \
    "proxies to loopback gunicorn and preserves TLS-aware forwarded proto" \
    templates/configmap-nginx.yaml \
    's|server 127\.0\.0\.1:{{ \$gunicornPort }}|server 0.0.0.0:{{ $gunicornPort }}|'

expect_mutation_detected \
    "forwarded proto forced back to this hop's scheme" \
    "proxies to loopback gunicorn and preserves TLS-aware forwarded proto" \
    templates/configmap-nginx.yaml \
    's|proxy_set_header X-Forwarded-Proto \$indi_allsky_forwarded_proto;|proxy_set_header X-Forwarded-Proto $scheme;|'

# --- #5/#6: NetworkPolicy ----------------------------------------------------

expect_mutation_detected \
    "gunicorn port admitted by the web policy" \
    "admits nginx 8080 on the web pod and never gunicorn 8000" \
    templates/networkpolicy-web.yaml \
    's|^        - port: {{ include "indi-allsky.nginxPort" . \| int }}$|        - port: 8000|'

expect_mutation_detected \
    "database policy widened to the whole namespace" \
    "admits 3306 only from this release's database clients" \
    templates/networkpolicy-mariadb.yaml \
    's|^        - podSelector:$|        - namespaceSelector: {}\n        - podSelector:|'

# --- #6: PriorityClass identity and privilege --------------------------------

expect_mutation_detected \
    "PriorityClass identity stripped of namespace and spec" \
    "gives the PriorityClass a different name in a different namespace" \
    templates/_helpers.tpl \
    's|^      .Release.Namespace$|      ""|'

expect_mutation_detected \
    "restricted context weakened for every container that shares it" \
    "keeps the daemon restricted in every mode, including hostpath sensors" \
    templates/_helpers.tpl \
    's|^allowPrivilegeEscalation: false$|allowPrivilegeEscalation: true|'

# --- #6: secure defaults -----------------------------------------------------

expect_mutation_detected \
    "hostPath restored as the default device mode" \
    "is schedulable anywhere with the secure defaults" \
    values.yaml \
    's|^    mode: none$|    mode: hostpath|'

expect_mutation_detected \
    "overlay barrier removed from the edge pod" \
    "gates startup on the exact applied-overlay checksum" \
    templates/edge-deployment.yaml \
    's|command: \["/home/allsky/wait-overlay.sh"\]|command: ["/bin/true"]|'

# --- #22: the checksum the migration path verifies ---------------------------

expect_mutation_detected \
    "canonical overlay bytes replaced by the pretty rendering" \
    "publishes the byte-exact canonical bytes the checksum covers" \
    templates/configmap-overlay.yaml \
    's|^  config-overlay.canonical.json: {{ \$canonical \| toJson }}$|  config-overlay.canonical.json: {{ $canonical \| fromJson \| toPrettyJson \| toJson }}|'

printf 'mutation controls: %d contract mutations detected\n' "$case_number"
