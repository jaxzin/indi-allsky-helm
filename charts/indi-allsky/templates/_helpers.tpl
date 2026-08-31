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

{{- define "indi-allsky.mariadbDataPvcName" -}}
{{ include "indi-allsky.resourceName" (dict "ctx" . "suffix" "mariadb-data" "maxLength" 63) }}
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

{{- define "indi-allsky.webName" -}}
{{ include "indi-allsky.resourceName" (dict "ctx" . "suffix" "web" "maxLength" 63) }}
{{- end }}

{{/* Services are DNS-1035: 63 characters and never digit-leading, hence alphaPrefix. */}}
{{- define "indi-allsky.webServiceName" -}}
{{ include "indi-allsky.resourceName" (dict "ctx" . "suffix" "web" "maxLength" 63 "alphaPrefix" "svc") }}
{{- end }}

{{- define "indi-allsky.nginxConfigMapName" -}}
{{ include "indi-allsky.resourceName" (dict "ctx" . "suffix" "nginx" "maxLength" 63) }}
{{- end }}

{{- define "indi-allsky.edgeName" -}}
{{ include "indi-allsky.resourceName" (dict "ctx" . "suffix" "edge" "maxLength" 63) }}
{{- end }}

{{- define "indi-allsky.mosquittoName" -}}
{{ include "indi-allsky.resourceName" (dict "ctx" . "suffix" "mosquitto" "maxLength" 63) }}
{{- end }}

{{/* Services are DNS-1035: 63 characters and never digit-leading, hence alphaPrefix. */}}
{{- define "indi-allsky.mosquittoServiceName" -}}
{{ include "indi-allsky.resourceName" (dict "ctx" . "suffix" "mosquitto" "maxLength" 63 "alphaPrefix" "svc") }}
{{- end }}

{{/*
Cluster-scoped NodeFeatureRule identity, on the same reasoning as
indi-allsky.priorityClassName: a NodeFeatureRule is CLUSTER-scoped while a Helm
release is not, so a name derived from release and chart alone collides between
two releases that share a release name in different namespaces — the ordinary
case. The hash input carries the namespace and the raw release/chart identity,
so every release gets its own object.

Deliberately NOT the PriorityClass's share-when-identical behaviour: two
releases rendering the same rule would still be two Helm releases claiming one
cluster-scoped object, and the second install would fail on ownership. Two
rules that both label a node indi-allsky.io/camera=true are harmless — NFD
unions the labels from every rule that matches.
*/}}
{{- define "indi-allsky.nfdRuleName" -}}
{{- $identity := printf "%s/%s" .Release.Namespace (include "indi-allsky.rawFullname" .) -}}
{{- $prefix := include "indi-allsky.resourceName" (dict "ctx" . "suffix" "camera" "maxLength" 52) -}}
{{- printf "%s-%s" $prefix (sha256sum $identity | trunc 10) -}}
{{- end }}

{{/*
Cluster-scoped PriorityClass identity. A generated name derived from release
and chart alone collides across namespaces, so the hash input carries the
namespace, the raw release/chart identity, and the spec this release intends
(value plus preemption policy). Two releases that would render an identical
class share the name; anything that differs gets its own object rather than
silently adopting someone else's scheduling contract.
*/}}
{{- define "indi-allsky.priorityClassName" -}}
{{- if eq .Values.edge.priorityClass.mode "reference" -}}
{{- .Values.edge.priorityClass.name -}}
{{- else -}}
{{- $identity := printf "%s/%s/%d/%s"
      .Release.Namespace
      (include "indi-allsky.rawFullname" .)
      (int .Values.edge.priorityClass.value)
      .Values.edge.priorityClass.preemptionPolicy -}}
{{- $prefix := include "indi-allsky.resourceName" (dict "ctx" . "suffix" "capture" "maxLength" 52) -}}
{{- printf "%s-%s" $prefix (sha256sum $identity | trunc 10) -}}
{{- end -}}
{{- end }}

{{- define "indi-allsky.dbHost" -}}
{{- if .Values.mariadb.enabled }}{{ include "indi-allsky.mariadbServiceName" . }}{{ else }}{{ required "externalDatabase.host is required when mariadb.enabled=false" .Values.externalDatabase.host }}{{ end }}
{{- end }}

{{/* Internal contract constants. They are intentionally not public values. */}}
{{- define "indi-allsky.appUid" -}}10001{{- end }}
{{- define "indi-allsky.mariadbUid" -}}999{{- end }}
{{- define "indi-allsky.mariadbPort" -}}3306{{- end }}
{{/*
The uid/gid eclipse-mosquitto establishes for itself (`mosquitto:x:1883:1883`
in the image's /etc/passwd, and the owner of its whole /mosquitto tree). The
image ships no USER directive, so without this the broker would run as root;
the chart's own 10001 would be equally wrong, because nothing in the image is
owned by it. Verified against the published eclipse-mosquitto:2.0 layers.
*/}}
{{- define "indi-allsky.mosquittoUid" -}}1883{{- end }}
{{- define "indi-allsky.mosquittoPort" -}}1883{{- end }}
{{/*
The image's own unauthenticated config: `listener 1883` plus
`allow_anonymous true`. Mosquitto 2.0's packaged default config
(/mosquitto/config/mosquitto.conf) is entirely commented out, which means a
local-only listener with anonymous access denied — unreachable from any other
pod. v1 ships the broker without authentication (see docs/topologies.md), so
this is the config that matches what the chart actually offers.
*/}}
{{- define "indi-allsky.mosquittoConfigPath" -}}/mosquitto-no-auth.conf{{- end }}
{{- define "indi-allsky.dataMountPath" -}}/var/www/html{{- end }}
{{- define "indi-allsky.appDataPath" -}}/var/www/html/allsky{{- end }}
{{- define "indi-allsky.imagePath" -}}/var/www/html/allsky/images{{- end }}
{{- define "indi-allsky.migrationPath" -}}/var/www/html/allsky/.state/migrations{{- end }}
{{- define "indi-allsky.backupPath" -}}/var/www/html/.state/backups{{- end }}
{{- define "indi-allsky.overlayMountPath" -}}/etc/indi-allsky-overlay{{- end }}
{{/*
The checksum is taken over the canonical compact bytes, so the file the
migration path reads and hashes must BE those bytes. The pretty sibling in the
same ConfigMap is for operators reading `kubectl get cm`; hashing it would
compare a pretty-printed rendering against a compact digest and never match.
*/}}
{{- define "indi-allsky.overlayPath" -}}/etc/indi-allsky-overlay/config-overlay.canonical.json{{- end }}
{{- define "indi-allsky.overlaySentinelPath" -}}/var/www/html/.state/config-overlay.applied{{- end }}
{{- define "indi-allsky.configPath" -}}/etc/indi-allsky{{- end }}

{{/* Container ports. gunicorn's is loopback-only inside the web pod. */}}
{{- define "indi-allsky.gunicornPort" -}}8000{{- end }}
{{- define "indi-allsky.nginxPort" -}}8080{{- end }}
{{- define "indi-allsky.indiserverPort" -}}7624{{- end }}

{{/*
Upstream serves its Flask blueprint under /indi-allsky and its static assets
from the checkout at the path below. The static-copy init container copies that
directory into an emptyDir so nginx can serve it without mounting the
application image's filesystem.
*/}}
{{- define "indi-allsky.appUrlPrefix" -}}/indi-allsky{{- end }}
{{- define "indi-allsky.staticSourcePath" -}}/home/allsky/indi-allsky/indi_allsky/flask/static{{- end }}
{{- define "indi-allsky.staticServePath" -}}/usr/share/nginx/indi-allsky-static{{- end }}

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

{{/*
The restricted container securityContext every non-device container in this
chart carries. One definition so "restricted" cannot mean two different things
in two templates, and so a container that drops it is a visible deletion.
usage: {{ include "indi-allsky.restrictedSecurityContext" . | nindent 12 }}
*/}}
{{- define "indi-allsky.restrictedSecurityContext" -}}
{{- $appUid := include "indi-allsky.appUid" . | int -}}
runAsNonRoot: true
runAsUser: {{ $appUid }}
runAsGroup: {{ $appUid }}
allowPrivilegeEscalation: false
capabilities:
  drop:
    - ALL
seccompProfile:
  type: RuntimeDefault
{{- end }}

{{/*
Explicit per-container application-Secret allowlist. The application Secret is
never consumed through a blanket envFrom: that would let an opaque Secret
override chart-owned configuration and would hand every container every
credential. Each caller names only the optional groups it actually uses.

Optional keys are projected with optional: true because the chart cannot see
inside credentials.existingSecret. A missing optional key leaves the variable
unset, so a value the env ConfigMap already rendered still applies.

usage: {{ include "indi-allsky.appSecretEnv" (dict "ctx" . "oidc" true "adminSeed" true) | nindent 12 }}
*/}}
{{- define "indi-allsky.appSecretEnv" -}}
{{- $ctx := .ctx -}}
{{- $secretName := include "indi-allsky.envSecretName" $ctx -}}
- name: INDIALLSKY_FLASK_SECRET_KEY
  valueFrom:
    secretKeyRef:
      name: {{ $secretName }}
      key: INDIALLSKY_FLASK_SECRET_KEY
- name: INDIALLSKY_FLASK_PASSWORD_KEY
  valueFrom:
    secretKeyRef:
      name: {{ $secretName }}
      key: INDIALLSKY_FLASK_PASSWORD_KEY
- name: MARIADB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ $secretName }}
      key: MARIADB_PASSWORD
{{- if and .oidc $ctx.Values.oidc.enabled }}
- name: INDIALLSKY_OIDC_CLIENT_ID
  valueFrom:
    secretKeyRef:
      name: {{ $secretName }}
      key: INDIALLSKY_OIDC_CLIENT_ID
      optional: true
- name: INDIALLSKY_OIDC_CLIENT_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ $secretName }}
      key: INDIALLSKY_OIDC_CLIENT_SECRET
      optional: true
- name: INDIALLSKY_OIDC_DISCOVERY_ENDPOINT
  valueFrom:
    secretKeyRef:
      name: {{ $secretName }}
      key: INDIALLSKY_OIDC_DISCOVERY_ENDPOINT
      optional: true
{{- end }}
{{- if and .adminSeed $ctx.Values.adminUser.username }}
- name: INDIALLSKY_WEB_PASS
  valueFrom:
    secretKeyRef:
      name: {{ $secretName }}
      key: INDIALLSKY_WEB_PASS
      optional: true
{{- end }}
{{- end }}

{{/*
Merges device-plugin extended resources into a container's requests AND limits
without replacing the base cpu/memory entries. Extended resources must appear
in limits, and Kubernetes copies limits to requests only when requests are
absent — this chart sets both explicitly so a base `requests` block cannot
swallow the device request.
usage: {{ include "indi-allsky.containerResources" (dict "base" .Values.edge.resources "devices" $deviceResources) | nindent 12 }}
*/}}
{{- define "indi-allsky.containerResources" -}}
{{- $base := deepCopy (.base | default dict) -}}
{{- $devices := .devices | default dict -}}
{{- if $devices -}}
  {{- $requests := mustMergeOverwrite (deepCopy (dig "requests" (dict) $base)) (deepCopy $devices) -}}
  {{- $limits := mustMergeOverwrite (deepCopy (dig "limits" (dict) $base)) (deepCopy $devices) -}}
  {{- $_ := set $base "requests" $requests -}}
  {{- $_ := set $base "limits" $limits -}}
{{- end -}}
{{- if $base -}}
{{- toYaml $base -}}
{{- end -}}
{{- end }}

{{/*
Deterministic volume name for one hostPath entry. Derived from the path so two
entries can never collide and the same path always renders the same name.
usage: {{ include "indi-allsky.hostPathVolumeName" (dict "role" "camera" "index" $index) }}
*/}}
{{- define "indi-allsky.hostPathVolumeName" -}}
{{- printf "%s-device-%d" .role (int .index) -}}
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
