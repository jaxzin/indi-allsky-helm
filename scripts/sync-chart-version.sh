#!/bin/bash
# The one command that changes this repo's chart version. Everywhere a
# concrete version has to appear in tracked source — Chart.yaml's `version:`
# field, and the handful of functional fields in the README/examples that
# genuinely need a literal pin (a `helm --version` flag, a Flux/ArgoCD
# `version:`/`targetRevision:`) — is written here, from one input, in one
# commit. There is no second place that needs hand-editing, and nothing here
# is meant to be run piecemeal.
#
# Illustrative prose that merely explains a mechanism (e.g. "a range like
# 0.1.x would let a patch land unreviewed") deliberately does NOT name a
# concrete version and is out of scope for this script — see the comments in
# the files themselves. Anything describing what a SPECIFIC release covers or
# pins belongs on that release's GitHub Release object (release.yml composes
# it from the tag), never hand-maintained here.
#
# Usage:
#   scripts/sync-chart-version.sh <version>   write <version> into Chart.yaml
#                                              and every tracked reference,
#                                              in the working tree. Review the
#                                              diff and commit it yourself —
#                                              that commit is what release.yml
#                                              expects `chart-v<version>` to
#                                              tag.
#   scripts/sync-chart-version.sh --check     change nothing. Exit 1 with a
#                                              diff if any tracked reference
#                                              disagrees with Chart.yaml's
#                                              CURRENT version — i.e. someone
#                                              edited a version by hand
#                                              instead of through this script.
#                                              This is what CI runs.
#
# <version> must already be the exact string release.yml's tag-derived
# version will be compared against — this script does not itself validate
# SemVer shape beyond "non-empty", since Chart.yaml's own schema and the
# release pin gate are the enforcing checks, not this one.

set -o errexit
set -o nounset
set -o pipefail

cd "$(dirname "$0")/.."   # repo root, regardless of the caller's cwd

CHART_FILE="charts/indi-allsky/Chart.yaml"

MODE="bump"
NEW_VERSION="${1:-}"
if [ "$NEW_VERSION" == "--check" ]; then
    MODE="check"
    NEW_VERSION=""
fi

if [ "$MODE" == "bump" ]; then
    if [ -z "$NEW_VERSION" ]; then
        echo "usage: $0 <version> | $0 --check" >&2
        exit 1
    fi
    yq -i ".version = \"${NEW_VERSION}\"" "$CHART_FILE"
fi

CHART_VERSION="$(yq -r .version "$CHART_FILE")"
CHART_TAG="chart-v${CHART_VERSION}"

# file | sed expression. Each expression's pattern is scoped to the exact
# field it targets (README's install command, the example manifests' pinned
# fields) — never a bare version-shaped string anywhere in a file — so
# coincidental digits elsewhere in prose are never touched.
targets=(
    "README.md|s/--version [0-9][^ ]*/--version ${CHART_VERSION}/"
    'examples/flux-helmrelease.yaml|s/version: "[0-9][^"]*"/version: "'"${CHART_VERSION}"'"/'
    "examples/argocd-application.yaml|s/targetRevision: [0-9][^ ]*/targetRevision: ${CHART_VERSION}/"
    "examples/argocd-application.yaml|s/targetRevision: chart-v[0-9][^ ]*/targetRevision: ${CHART_TAG}/"
)

stale=false
for target in "${targets[@]}"; do
    file="${target%%|*}"
    expr="${target#*|}"

    if [ "$MODE" == "check" ]; then
        if ! diff -u "$file" <(sed -E "$expr" "$file") --label "$file (tracked)" --label "$file (from ${CHART_FILE} ${CHART_VERSION})"; then
            stale=true
        fi
    else
        sed -i.bak -E "$expr" "$file" && rm -f "${file}.bak"
    fi
done

if [ "$MODE" == "check" ]; then
    if $stale; then
        echo "::error::one or more files disagree with ${CHART_FILE}'s version (${CHART_VERSION}) — a version was edited by hand instead of through scripts/sync-chart-version.sh. Run 'scripts/sync-chart-version.sh ${CHART_VERSION}' and commit the result." >&2
        exit 1
    fi
    echo "All tracked version references match ${CHART_FILE} (${CHART_VERSION})"
else
    echo "Set chart version to ${CHART_VERSION} (tag ${CHART_TAG}) everywhere it is tracked. Review the diff and commit it — that commit is what gets tagged."
fi
