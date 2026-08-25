#!/usr/bin/env bash
set -Eeuo pipefail

readonly validation_call='{{- include "indi-allsky.validateValues" . -}}'
chart_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly chart_dir
readonly templates=(
  configmap-env.yaml
  configmap-overlay.yaml
  secret-env.yaml
  secret-mariadb-root.yaml
  mariadb-service.yaml
  mariadb-statefulset.yaml
  mariadb-backup-cronjob.yaml
  validate.yaml
)

for template in "${templates[@]}"; do
  template_path="${chart_dir}/templates/${template}"
  if ! grep -Fq -- "$validation_call" "$template_path"; then
    printf 'FATAL: %s does not invoke centralized A5 validation\n' "$template_path" >&2
    exit 1
  fi
  printf 'validation wired: %s\n' "$template"
done
