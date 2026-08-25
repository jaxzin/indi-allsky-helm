{{- define "indi-allsky.fullname" -}}
{{- if contains .Chart.Name .Release.Name }}{{ .Release.Name | trunc 63 | trimSuffix "-" }}{{ else }}{{ printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" }}{{ end }}
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
{{- if .Values.storage.data.existingClaim }}{{ .Values.storage.data.existingClaim }}{{ else }}{{ include "indi-allsky.fullname" . }}-data{{ end }}
{{- end }}

{{- define "indi-allsky.envSecretName" -}}
{{- if .Values.credentials.existingSecret }}{{ .Values.credentials.existingSecret }}{{ else }}{{ include "indi-allsky.fullname" . }}-env{{ end }}
{{- end }}

{{- define "indi-allsky.envConfigMapName" -}}
{{ include "indi-allsky.fullname" . }}-env
{{- end }}

{{- define "indi-allsky.dbHost" -}}
{{- if .Values.mariadb.enabled }}{{ include "indi-allsky.fullname" . }}-mariadb{{ else }}{{ required "externalDatabase.host is required when mariadb.enabled=false" .Values.externalDatabase.host }}{{ end }}
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
