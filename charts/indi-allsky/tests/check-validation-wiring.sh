#!/usr/bin/env bash
set -Eeuo pipefail

readonly validation_call='{{- include "indi-allsky.validateValues" . -}}'
chart_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly chart_dir
readonly templates=(
  configmap-env.yaml
  configmap-nginx.yaml
  configmap-overlay.yaml
  edge-deployment.yaml
  mariadb-backup-cronjob.yaml
  mariadb-service.yaml
  mariadb-statefulset.yaml
  mosquitto-deployment.yaml
  mosquitto-service.yaml
  networkpolicy-edge.yaml
  networkpolicy-mariadb.yaml
  networkpolicy-mosquitto.yaml
  networkpolicy-web.yaml
  nfd-rule.yaml
  priorityclass.yaml
  pvc-data.yaml
  pvc-mariadb.yaml
  secret-env.yaml
  secret-mariadb-root.yaml
  validate.yaml
  web-deployment.yaml
  web-ingress.yaml
  web-service.yaml
)

# The list above must name every template in the chart. A new template that
# forgot the validation call would otherwise render a manifest from values
# nothing had checked, and this script would still pass by simply not knowing
# the template existed.
chart_templates="$(
  find "${chart_dir}/templates" -maxdepth 1 -type f -name '*.yaml' -exec basename {} \; | sort
)"
declared_templates="$(printf '%s\n' "${templates[@]}" | sort)"
if [ "$chart_templates" != "$declared_templates" ]; then
  printf 'FATAL: the validation-wiring list and templates/ have diverged\n' >&2
  diff <(printf '%s\n' "$declared_templates") <(printf '%s\n' "$chart_templates") >&2 || true
  exit 1
fi

for template in "${templates[@]}"; do
  template_path="${chart_dir}/templates/${template}"
  if ! grep -Fq -- "$validation_call" "$template_path"; then
    printf 'FATAL: %s does not invoke centralized validation\n' "$template_path" >&2
    exit 1
  fi
  printf 'validation wired: %s\n' "$template"
done
