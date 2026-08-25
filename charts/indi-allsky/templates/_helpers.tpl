{{- define "indi-allsky.rawFullname" -}}
{{- if contains .Chart.Name .Release.Name }}{{ .Release.Name }}{{ else }}{{ printf "%s-%s" .Release.Name .Chart.Name }}{{ end }}
{{- end }}

{{/*
Create a DNS-label-safe generated name while preserving the semantic suffix.
Names changed by normalization or truncation use <prefix>-<8-char hash>-<suffix>.
The hash is derived from the original candidate, so dotted and dashed release
names cannot normalize to the same resource name. Callers producing a Service
pass alphaPrefix so a digit-leading Helm release remains accepted without
violating the Kubernetes 1.26 DNS-1035 Service-name rule. CronJobs pass
maxLength=52 so the controller has room for its 11-character Job suffix.
Usage: include "indi-allsky.resourceName" (dict "ctx" . "suffix" "mariadb" "maxLength" 63)
*/}}
{{- define "indi-allsky.resourceName" -}}
{{- $ctx := .ctx -}}
{{- $suffix := .suffix | default "" -}}
{{- $maxLength := int (.maxLength | default 63) -}}
{{- $alphaPrefix := .alphaPrefix | default "" -}}
{{- $rawBase := include "indi-allsky.rawFullname" $ctx -}}
{{- $base := regexReplaceAll "[^a-z0-9-]+" (lower $rawBase) "-" | trimAll "-" -}}
{{- if eq $base "" }}{{ fail "release and chart names must contain at least one DNS-label character" }}{{ end -}}
{{- $rawCandidate := $rawBase -}}
{{- if $suffix -}}
  {{- $rawCandidate = printf "%s-%s" $rawBase $suffix -}}
{{- end -}}
{{- $normalizationChanged := ne $rawBase $base -}}
{{- if and $alphaPrefix (regexMatch "^[0-9]" $base) -}}
  {{- $base = printf "%s-%s" $alphaPrefix $base -}}
  {{- $normalizationChanged = true -}}
{{- end -}}
{{- $candidate := $base -}}
{{- if $suffix -}}
  {{- $candidate = printf "%s-%s" $base $suffix -}}
{{- end -}}
{{- if and (not $normalizationChanged) (le (len $candidate) $maxLength) -}}
{{- $candidate | trimSuffix "-" -}}
{{- else -}}
  {{- $hash := sha256sum $rawCandidate | trunc 8 -}}
  {{- if $suffix -}}
    {{- $prefixLength := sub $maxLength (add (len $hash) (len $suffix) 2) -}}
    {{- if lt $prefixLength 1 }}{{ fail (printf "cannot fit resource suffix %q into %d characters" $suffix $maxLength) }}{{ end -}}
    {{- $prefix := $base | trunc (int $prefixLength) | trimSuffix "-" -}}
{{- printf "%s-%s-%s" $prefix $hash $suffix -}}
  {{- else -}}
    {{- $prefixLength := sub $maxLength (add (len $hash) 1) -}}
    {{- $prefix := $base | trunc (int $prefixLength) | trimSuffix "-" -}}
{{- printf "%s-%s" $prefix $hash -}}
  {{- end -}}
{{- end -}}
{{- end }}

{{- define "indi-allsky.fullname" -}}
{{ include "indi-allsky.resourceName" (dict "ctx" . "suffix" "" "maxLength" 63) }}
{{- end }}

{{- define "indi-allsky.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "indi-allsky.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/* usage: {{ include "indi-allsky.componentLabels" (dict "ctx" . "component" "web") }} */}}
{{- define "indi-allsky.componentLabels" -}}
{{ include "indi-allsky.selectorLabels" .ctx }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{- define "indi-allsky.dataPvcName" -}}
{{- if .Values.storage.data.existingClaim }}{{ .Values.storage.data.existingClaim }}{{ else }}{{ include "indi-allsky.resourceName" (dict "ctx" . "suffix" "data" "maxLength" 63) }}{{ end }}
{{- end }}

{{- define "indi-allsky.envSecretName" -}}
{{- if .Values.credentials.existingSecret }}{{ .Values.credentials.existingSecret }}{{ else }}{{ include "indi-allsky.resourceName" (dict "ctx" . "suffix" "env" "maxLength" 63) }}{{ end }}
{{- end }}

{{- define "indi-allsky.envConfigMapName" -}}
{{ include "indi-allsky.resourceName" (dict "ctx" . "suffix" "env" "maxLength" 63) }}
{{- end }}

{{- define "indi-allsky.overlayConfigMapName" -}}
{{ include "indi-allsky.resourceName" (dict "ctx" . "suffix" "config-overlay" "maxLength" 63) }}
{{- end }}

{{- define "indi-allsky.mariadbName" -}}
{{ include "indi-allsky.resourceName" (dict "ctx" . "suffix" "mariadb" "maxLength" 63) }}
{{- end }}

{{- define "indi-allsky.mariadbServiceName" -}}
{{ include "indi-allsky.resourceName" (dict "ctx" . "suffix" "mariadb" "maxLength" 63 "alphaPrefix" "svc") }}
{{- end }}

{{- define "indi-allsky.mariadbRootSecretName" -}}
{{- if .Values.mariadb.rootCredentials.existingSecret }}{{ .Values.mariadb.rootCredentials.existingSecret }}{{ else }}{{ include "indi-allsky.resourceName" (dict "ctx" . "suffix" "mariadb-root" "maxLength" 63) }}{{ end }}
{{- end }}

{{- define "indi-allsky.backupCronJobName" -}}
{{ include "indi-allsky.resourceName" (dict "ctx" . "suffix" "db-backup" "maxLength" 52) }}
{{- end }}

{{- define "indi-allsky.dbHost" -}}
{{- if .Values.mariadb.enabled }}{{ include "indi-allsky.mariadbServiceName" . }}{{ else }}{{ required "externalDatabase.host is required when mariadb.enabled=false" .Values.externalDatabase.host }}{{ end }}
{{- end }}

{{/* Internal contract constants. They are intentionally not public values. */}}
{{- define "indi-allsky.appUid" -}}10001{{- end }}
{{- define "indi-allsky.mariadbUid" -}}999{{- end }}
{{- define "indi-allsky.mariadbPort" -}}3306{{- end }}
{{- define "indi-allsky.dataMountPath" -}}/var/www/html{{- end }}
{{- define "indi-allsky.appDataPath" -}}/var/www/html/allsky{{- end }}
{{- define "indi-allsky.imagePath" -}}/var/www/html/allsky/images{{- end }}
{{- define "indi-allsky.migrationPath" -}}/var/www/html/allsky/.state/migrations{{- end }}
{{- define "indi-allsky.backupPath" -}}/var/www/html/.state/backups{{- end }}
{{- define "indi-allsky.overlayPath" -}}/etc/indi-allsky-overlay/config-overlay.json{{- end }}
{{- define "indi-allsky.overlaySentinelPath" -}}/var/www/html/.state/config-overlay.applied{{- end }}

{{/* Canonical compact JSON is the sole checksum input and rollout identity. */}}
{{- define "indi-allsky.overlayCanonicalJson" -}}
{{- $indiHost := "localhost" -}}
{{- $indiPort := 7624 -}}
{{- if eq .Values.indiserver.mode "external" -}}
  {{- $indiHost = .Values.indiserver.external.host -}}
  {{- $indiPort = int .Values.indiserver.external.port -}}
{{- end -}}
{{- $managed := dict "INDI_SERVER" $indiHost "INDI_PORT" $indiPort "IMAGE_FOLDER" (include "indi-allsky.imagePath" .) -}}
{{- mustMergeOverwrite (deepCopy .Values.appConfig) $managed | mustToJson -}}
{{- end }}

{{- define "indi-allsky.overlayChecksum" -}}
{{ include "indi-allsky.overlayCanonicalJson" . | sha256sum }}
{{- end }}

{{/* usage: {{ include "indi-allsky.image" (dict "ctx" . "name" "daemon") }} —
     renders registry/indi-allsky-<name>@digest when a digest pin is set,
     else registry/indi-allsky-<name>:tag (tag defaults to appVersion) */}}
{{- define "indi-allsky.image" -}}
{{- $digest := get .ctx.Values.image.digests .name -}}
{{- if $digest -}}
{{ .ctx.Values.image.registry }}/indi-allsky-{{ .name }}@{{ $digest }}
{{- else -}}
{{ .ctx.Values.image.registry }}/indi-allsky-{{ .name }}:{{ .ctx.Values.image.tag | default .ctx.Chart.AppVersion }}
{{- end -}}
{{- end }}
