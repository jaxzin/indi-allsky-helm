{{/* Central A5 validation. Every A5 manifest invokes this helper explicitly. */}}

{{- define "indi-allsky.validatePattern" -}}
{{- if not (kindIs "string" .value) -}}
  {{- fail (printf "%s must be a string" .name) -}}
{{- end -}}
{{- if and (not .allowEmpty) (eq .value "") -}}
  {{- fail (printf "%s must be set and non-empty" .name) -}}
{{- end -}}
{{- if and (ne .value "") (not (regexMatch .pattern .value)) -}}
  {{- fail (printf "%s %s" .name .description) -}}
{{- end -}}
{{- end }}

{{- define "indi-allsky.validateString" -}}
{{- if not (kindIs "string" .value) -}}
  {{- fail (printf "%s must be a string" .name) -}}
{{- end -}}
{{- if and (not .allowEmpty) (eq .value "") -}}
  {{- fail (printf "%s must be set and non-empty" .name) -}}
{{- end -}}
{{- end }}

{{- define "indi-allsky.validateEnum" -}}
{{- if not (kindIs "string" .value) -}}
  {{- fail (printf "%s must be a string" .name) -}}
{{- end -}}
{{- if not (has .value .allowed) -}}
  {{- fail (printf "%s must be one of: %s" .name (join ", " .allowed)) -}}
{{- end -}}
{{- end }}

{{- define "indi-allsky.validateBool" -}}
{{- if not (kindIs "bool" .value) -}}
  {{- fail (printf "%s must be a boolean" .name) -}}
{{- end -}}
{{- end }}

{{- define "indi-allsky.validateIntegerAtLeast" -}}
{{- $kind := kindOf .value -}}
{{- if not (has $kind (list "int" "int32" "int64" "float64")) -}}
  {{- fail (printf "%s must be a whole number >= %d" .name (int .minimum)) -}}
{{- end -}}
{{/* Wholeness is tested numerically, not against a rendering. Helm parses every
     YAML number as float64 and Go prints large ones in exponent form —
     1000000 becomes "1e+06" and 1000000001 becomes "1.000000001e+09" — so a
     regex over the printed form either rejects legitimate whole numbers or has
     to accept a decimal point and stop catching real fractions. Truncating and
     comparing back has neither problem. */}}
{{- if ne (float64 (int64 .value)) (float64 .value) -}}
  {{- fail (printf "%s must be a whole number >= %d" .name (int .minimum)) -}}
{{- end -}}
{{- if lt (int64 .value) (int64 .minimum) -}}
  {{- fail (printf "%s must be >= %d" .name (int .minimum)) -}}
{{- end -}}
{{- end }}

{{- define "indi-allsky.validateDnsSubdomain" -}}
{{- include "indi-allsky.validateString" (dict "name" .name "value" .value "allowEmpty" true) -}}
{{- if .value -}}
  {{- if gt (len .value) 253 }}{{ fail (printf "%s must be at most 253 characters" .name) }}{{ end -}}
  {{- range $label := splitList "." .value -}}
    {{- if or (gt (len $label) 63) (not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" $label)) -}}
      {{- fail (printf "%s must be a valid DNS subdomain %s" $.name $.objectKind) -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- end }}

{{- define "indi-allsky.validateSecretName" -}}
{{- include "indi-allsky.validateDnsSubdomain" (dict "name" .name "value" .value "objectKind" "Secret name") -}}
{{- end }}

{{- define "indi-allsky.validateIntegerList" -}}
{{- if not (kindIs "slice" .value) -}}
  {{- fail (printf "%s must be a list of whole numbers" .name) -}}
{{- end -}}
{{- range $index, $entry := .value -}}
  {{- include "indi-allsky.validateIntegerAtLeast" (dict "name" (printf "%s[%d]" $.name $index) "value" $entry "minimum" $.minimum) -}}
{{- end -}}
{{- end }}

{{/*
Structured host device entries. Bare strings are rejected on purpose: the chart
renders the readOnly and hostPath type an operator states and never infers
device access from the shape of a path.
*/}}
{{- define "indi-allsky.validateHostPathList" -}}
{{- if not (kindIs "slice" .value) -}}
  {{- fail (printf "%s must be a list of {path, type, readOnly} objects" .name) -}}
{{- end -}}
{{- range $index, $entry := .value -}}
  {{- $label := printf "%s[%d]" $.name $index -}}
  {{- if not (kindIs "map" $entry) -}}
    {{- fail (printf "%s must be an object with exactly the fields path, type and readOnly" $label) -}}
  {{- end -}}
  {{- if or (ne (len $entry) 3) (not (hasKey $entry "path")) (not (hasKey $entry "type")) (not (hasKey $entry "readOnly")) -}}
    {{- fail (printf "%s must contain exactly the fields path, type and readOnly" $label) -}}
  {{- end -}}
  {{- include "indi-allsky.validatePattern" (dict "name" (printf "%s.path" $label) "value" (get $entry "path") "pattern" "^/[^[:space:]]*$" "allowEmpty" false "description" "must be an absolute path with no whitespace") -}}
  {{- include "indi-allsky.validateEnum" (dict "name" (printf "%s.type" $label) "value" (get $entry "type") "allowed" (list "Directory" "CharDevice")) -}}
  {{- include "indi-allsky.validateBool" (dict "name" (printf "%s.readOnly" $label) "value" (get $entry "readOnly")) -}}
{{- end -}}
{{- end }}

{{- define "indi-allsky.validateStringList" -}}
{{- if not (kindIs "slice" .value) -}}
  {{- fail (printf "%s must be a list of strings" .name) -}}
{{- end -}}
{{- range $index, $entry := .value -}}
  {{- if or (not (kindIs "string" $entry)) (eq $entry "") -}}
    {{- fail (printf "%s[%d] must be a non-empty string" $.name $index) -}}
  {{- end -}}
{{- end -}}
{{- end }}

{{- define "indi-allsky.validateValues" -}}
{{- $dbPattern := "^[A-Za-z0-9_$-]+$" -}}
{{- $hostPattern := "^[A-Za-z0-9._:-]+$" -}}
{{- $charsetPattern := "^[A-Za-z0-9_]+$" -}}

{{- if not (kindIs "map" .Values.appConfig) -}}
  {{- fail "appConfig must be a map/object" -}}
{{- end -}}
{{- if not (kindIs "slice" .Values.image.pullSecrets) -}}
  {{- fail "image.pullSecrets must be a list of objects containing only a non-empty string name" -}}
{{- end -}}
{{- range $index, $entry := .Values.image.pullSecrets -}}
  {{- if not (kindIs "map" $entry) -}}
    {{- fail (printf "image.pullSecrets[%d] must be an object containing only a non-empty string name" $index) -}}
  {{- end -}}
  {{- if or (ne (len $entry) 1) (not (hasKey $entry "name")) -}}
    {{- fail (printf "image.pullSecrets[%d] must contain only the name field" $index) -}}
  {{- end -}}
  {{- $name := get $entry "name" -}}
  {{- if or (not (kindIs "string" $name)) (eq $name "") -}}
    {{- fail (printf "image.pullSecrets[%d].name must be a non-empty string" $index) -}}
  {{- end -}}
  {{- include "indi-allsky.validateSecretName" (dict "name" (printf "image.pullSecrets[%d].name" $index) "value" $name) -}}
{{- end -}}

{{- include "indi-allsky.validateBool" (dict "name" "mariadb.enabled" "value" .Values.mariadb.enabled) -}}
{{- include "indi-allsky.validateBool" (dict "name" "mariadb.backup.enabled" "value" .Values.mariadb.backup.enabled) -}}
{{- include "indi-allsky.validateBool" (dict "name" "externalDatabase.ssl" "value" .Values.externalDatabase.ssl) -}}
{{- include "indi-allsky.validateBool" (dict "name" "migrations.preMigrateDump" "value" .Values.migrations.preMigrateDump) -}}
{{- include "indi-allsky.validateBool" (dict "name" "web.authAllViews" "value" .Values.web.authAllViews) -}}
{{- include "indi-allsky.validateBool" (dict "name" "web.sessionCookieSecure" "value" .Values.web.sessionCookieSecure) -}}
{{- include "indi-allsky.validateBool" (dict "name" "oidc.enabled" "value" .Values.oidc.enabled) -}}
{{- include "indi-allsky.validateBool" (dict "name" "oidc.autoLogin" "value" .Values.oidc.autoLogin) -}}
{{- include "indi-allsky.validateBool" (dict "name" "oidc.localAuth" "value" .Values.oidc.localAuth) -}}
{{- include "indi-allsky.validateBool" (dict "name" "edge.darks.enabled" "value" .Values.edge.darks.enabled) -}}
{{- include "indi-allsky.validateBool" (dict "name" "edge.darks.daytime" "value" .Values.edge.darks.daytime) -}}

{{- include "indi-allsky.validateIntegerAtLeast" (dict "name" "migrations.preMigrateDumpKeep" "value" .Values.migrations.preMigrateDumpKeep "minimum" 1) -}}
{{- include "indi-allsky.validateIntegerAtLeast" (dict "name" "mariadb.backup.retentionDays" "value" .Values.mariadb.backup.retentionDays "minimum" 1) -}}
{{- include "indi-allsky.validateIntegerAtLeast" (dict "name" "edge.darks.bitmax" "value" .Values.edge.darks.bitmax "minimum" 1) -}}

{{- include "indi-allsky.validateEnum" (dict "name" "indiserver.mode" "value" .Values.indiserver.mode "allowed" (list "sidecar" "external")) -}}
{{- include "indi-allsky.validateEnum" (dict "name" "edge.devices.mode" "value" .Values.edge.devices.mode "allowed" (list "hostpath" "device-plugin" "none")) -}}
{{- include "indi-allsky.validateEnum" (dict "name" "edge.darks.mode" "value" .Values.edge.darks.mode "allowed" (list "flush" "average" "tempaverage" "sigmaclip" "tempsigmaclip")) -}}
{{- include "indi-allsky.validateEnum" (dict "name" "image.pullPolicy" "value" .Values.image.pullPolicy "allowed" (list "Always" "IfNotPresent" "Never")) -}}
{{- include "indi-allsky.validateEnum" (dict "name" "storage.retentionPolicy" "value" .Values.storage.retentionPolicy "allowed" (list "Retain" "Delete")) -}}

{{- include "indi-allsky.validateStringList" (dict "name" "oidc.allowedGroups" "value" .Values.oidc.allowedGroups) -}}
{{- include "indi-allsky.validateStringList" (dict "name" "oidc.adminGroups" "value" .Values.oidc.adminGroups) -}}
{{- include "indi-allsky.validateStringList" (dict "name" "web.adminNetworks" "value" .Values.web.adminNetworks) -}}

{{- include "indi-allsky.validateString" (dict "name" "timezone" "value" .Values.timezone "allowEmpty" false) -}}
{{- include "indi-allsky.validateString" (dict "name" "mariadb.backup.schedule" "value" .Values.mariadb.backup.schedule "allowEmpty" true) -}}
{{- include "indi-allsky.validateString" (dict "name" "credentials.flaskSecretKey" "value" .Values.credentials.flaskSecretKey "allowEmpty" true) -}}
{{- include "indi-allsky.validateString" (dict "name" "credentials.flaskPasswordKey" "value" .Values.credentials.flaskPasswordKey "allowEmpty" true) -}}
{{- include "indi-allsky.validateString" (dict "name" "credentials.mariadbPassword" "value" .Values.credentials.mariadbPassword "allowEmpty" true) -}}
{{- include "indi-allsky.validateString" (dict "name" "credentials.adminPassword" "value" .Values.credentials.adminPassword "allowEmpty" true) -}}
{{- include "indi-allsky.validateString" (dict "name" "mariadb.rootCredentials.password" "value" .Values.mariadb.rootCredentials.password "allowEmpty" true) -}}
{{- include "indi-allsky.validateString" (dict "name" "oidc.clientSecret" "value" .Values.oidc.clientSecret "allowEmpty" true) -}}
{{- include "indi-allsky.validateString" (dict "name" "oidc.clientId" "value" .Values.oidc.clientId "allowEmpty" true) -}}
{{- include "indi-allsky.validateString" (dict "name" "oidc.discoveryEndpoint" "value" .Values.oidc.discoveryEndpoint "allowEmpty" true) -}}
{{- include "indi-allsky.validateString" (dict "name" "oidc.providerName" "value" .Values.oidc.providerName "allowEmpty" true) -}}
{{- include "indi-allsky.validateString" (dict "name" "oidc.usernameClaim" "value" .Values.oidc.usernameClaim "allowEmpty" false) -}}
{{- include "indi-allsky.validateString" (dict "name" "adminUser.username" "value" .Values.adminUser.username "allowEmpty" true) -}}
{{- include "indi-allsky.validateString" (dict "name" "adminUser.name" "value" .Values.adminUser.name "allowEmpty" true) -}}
{{- include "indi-allsky.validateString" (dict "name" "adminUser.email" "value" .Values.adminUser.email "allowEmpty" true) -}}
{{- include "indi-allsky.validateString" (dict "name" "storage.data.size" "value" .Values.storage.data.size "allowEmpty" false) -}}
{{- include "indi-allsky.validateString" (dict "name" "mariadb.persistence.size" "value" .Values.mariadb.persistence.size "allowEmpty" false) -}}

{{- include "indi-allsky.validatePattern" (dict "name" "externalDatabase.charset" "value" .Values.externalDatabase.charset "pattern" $charsetPattern "allowEmpty" false "description" "may contain only letters, digits, and underscore") -}}
{{- include "indi-allsky.validatePattern" (dict "name" "externalDatabase.collation" "value" .Values.externalDatabase.collation "pattern" $charsetPattern "allowEmpty" false "description" "may contain only letters, digits, and underscore") -}}
{{- include "indi-allsky.validatePattern" (dict "name" "edge.captureTmpDir" "value" .Values.edge.captureTmpDir "pattern" "^/.*" "allowEmpty" true "description" "must be an absolute path when set") -}}
{{- include "indi-allsky.validateSecretName" (dict "name" "credentials.existingSecret" "value" .Values.credentials.existingSecret) -}}
{{- include "indi-allsky.validateSecretName" (dict "name" "mariadb.rootCredentials.existingSecret" "value" .Values.mariadb.rootCredentials.existingSecret) -}}
{{- include "indi-allsky.validateDnsSubdomain" (dict "name" "storage.data.existingClaim" "value" .Values.storage.data.existingClaim "objectKind" "PersistentVolumeClaim name") -}}
{{- include "indi-allsky.validateDnsSubdomain" (dict "name" "storage.data.storageClassName" "value" .Values.storage.data.storageClassName "objectKind" "StorageClass name") -}}
{{- include "indi-allsky.validateDnsSubdomain" (dict "name" "mariadb.persistence.storageClassName" "value" .Values.mariadb.persistence.storageClassName "objectKind" "StorageClass name") -}}

{{- if .Values.mariadb.enabled -}}
  {{- include "indi-allsky.validatePattern" (dict "name" "mariadb.database" "value" .Values.mariadb.database "pattern" $dbPattern "allowEmpty" false "description" "may contain only letters, digits, underscore, hyphen, and dollar sign") -}}
  {{- include "indi-allsky.validatePattern" (dict "name" "mariadb.username" "value" .Values.mariadb.username "pattern" $dbPattern "allowEmpty" false "description" "may contain only letters, digits, underscore, hyphen, and dollar sign") -}}
  {{- if .Values.mariadb.rootCredentials.existingSecret -}}
    {{- if .Values.mariadb.rootCredentials.password }}{{ fail "mariadb.rootCredentials.password must be empty when mariadb.rootCredentials.existingSecret is set" }}{{ end -}}
  {{- else -}}
    {{- if not .Values.mariadb.rootCredentials.password }}{{ fail "mariadb.rootCredentials.password (or mariadb.rootCredentials.existingSecret) is required when mariadb.enabled=true" }}{{ end -}}
  {{- end -}}
{{- else -}}
  {{- include "indi-allsky.validatePattern" (dict "name" "externalDatabase.host" "value" .Values.externalDatabase.host "pattern" $hostPattern "allowEmpty" false "description" "may contain only letters, digits, dot, colon, hyphen, and underscore") -}}
  {{- include "indi-allsky.validatePattern" (dict "name" "externalDatabase.database" "value" .Values.externalDatabase.database "pattern" $dbPattern "allowEmpty" false "description" "may contain only letters, digits, underscore, hyphen, and dollar sign") -}}
  {{- include "indi-allsky.validatePattern" (dict "name" "externalDatabase.username" "value" .Values.externalDatabase.username "pattern" $dbPattern "allowEmpty" false "description" "may contain only letters, digits, underscore, hyphen, and dollar sign") -}}
  {{- include "indi-allsky.validateIntegerAtLeast" (dict "name" "externalDatabase.port" "value" .Values.externalDatabase.port "minimum" 1) -}}
  {{- if gt (int .Values.externalDatabase.port) 65535 }}{{ fail "externalDatabase.port must be <= 65535" }}{{ end -}}
  {{- if or .Values.mariadb.rootCredentials.existingSecret .Values.mariadb.rootCredentials.password }}{{ fail "mariadb.rootCredentials must be empty when mariadb.enabled=false" }}{{ end -}}
  {{- if .Values.mariadb.backup.enabled }}{{ fail "mariadb.backup.enabled cannot be true when mariadb.enabled=false" }}{{ end -}}
{{- end -}}

{{- if eq .Values.indiserver.mode "external" -}}
  {{- include "indi-allsky.validatePattern" (dict "name" "indiserver.external.host" "value" .Values.indiserver.external.host "pattern" $hostPattern "allowEmpty" false "description" "may contain only letters, digits, dot, colon, hyphen, and underscore") -}}
  {{- include "indi-allsky.validateIntegerAtLeast" (dict "name" "indiserver.external.port" "value" .Values.indiserver.external.port "minimum" 1) -}}
  {{- if gt (int .Values.indiserver.external.port) 65535 }}{{ fail "indiserver.external.port must be <= 65535" }}{{ end -}}
{{- end -}}

{{- if .Values.credentials.existingSecret -}}
  {{- if or .Values.credentials.flaskSecretKey .Values.credentials.flaskPasswordKey .Values.credentials.mariadbPassword .Values.credentials.adminPassword .Values.oidc.clientSecret -}}
    {{- fail "inline application secret values must be empty when credentials.existingSecret is set" -}}
  {{- end -}}
{{- else -}}
  {{- if not .Values.credentials.flaskSecretKey }}{{ fail "credentials.flaskSecretKey (or credentials.existingSecret) is required" }}{{ end -}}
  {{- if not .Values.credentials.flaskPasswordKey }}{{ fail "credentials.flaskPasswordKey (or credentials.existingSecret) is required" }}{{ end -}}
  {{- if not .Values.credentials.mariadbPassword }}{{ fail "credentials.mariadbPassword (or credentials.existingSecret) is required" }}{{ end -}}
{{- end -}}

{{- if and .Values.mariadb.enabled (eq (include "indi-allsky.envSecretName" .) (include "indi-allsky.mariadbRootSecretName" .)) -}}
  {{- fail "the resolved application and MariaDB root Secret names must be different" -}}
{{- end -}}

{{- if and (not .Values.oidc.localAuth) (not .Values.oidc.enabled) }}{{ fail "oidc.localAuth=false requires oidc.enabled=true so a login method remains available" }}{{ end -}}
{{- if and .Values.oidc.autoLogin (not .Values.oidc.enabled) }}{{ fail "oidc.autoLogin=true requires oidc.enabled=true" }}{{ end -}}
{{- if and .Values.oidc.enabled (not .Values.credentials.existingSecret) -}}
  {{- if not .Values.oidc.clientId }}{{ fail "oidc.clientId (or credentials.existingSecret) is required when oidc.enabled=true" }}{{ end -}}
  {{- if not .Values.oidc.discoveryEndpoint }}{{ fail "oidc.discoveryEndpoint (or credentials.existingSecret) is required when oidc.enabled=true" }}{{ end -}}
{{- end -}}
{{- if and (not .Values.oidc.enabled) .Values.oidc.clientSecret }}{{ fail "oidc.clientSecret must be empty when oidc.enabled=false" }}{{ end -}}

{{- if .Values.adminUser.username -}}
  {{- if not .Values.oidc.localAuth }}{{ fail "adminUser.username must be empty when oidc.localAuth=false" }}{{ end -}}
  {{- include "indi-allsky.validatePattern" (dict "name" "adminUser.username" "value" .Values.adminUser.username "pattern" "^[^[:space:]]+$" "allowEmpty" false "description" "must not contain whitespace") -}}
  {{- include "indi-allsky.validatePattern" (dict "name" "adminUser.email" "value" .Values.adminUser.email "pattern" "^[^@]+@[^@]+\\.[^@]+$" "allowEmpty" false "description" "must be a valid email address") -}}
  {{- if eq .Values.adminUser.name "" }}{{ fail "adminUser.name must be set and non-empty when seeding adminUser.username" }}{{ end -}}
  {{- if and (not .Values.credentials.existingSecret) (lt (len .Values.credentials.adminPassword) 8) }}{{ fail "credentials.adminPassword must be at least 8 characters when seeding adminUser.username" }}{{ end -}}
{{- else if .Values.credentials.adminPassword -}}
  {{- fail "credentials.adminPassword must be empty when adminUser.username is empty" -}}
{{- end -}}

{{- if and .Values.mariadb.backup.enabled (eq (trim .Values.mariadb.backup.schedule) "") }}{{ fail "mariadb.backup.schedule must be non-empty when scheduled backups are enabled" }}{{ end -}}

{{/* --- network policy, web service and ingress ---------------------------- */}}
{{- include "indi-allsky.validateBool" (dict "name" "networkPolicy.enabled" "value" .Values.networkPolicy.enabled) -}}
{{- include "indi-allsky.validateIntegerAtLeast" (dict "name" "web.service.port" "value" .Values.web.service.port "minimum" 1) -}}
{{- if gt (int .Values.web.service.port) 65535 }}{{ fail "web.service.port must be <= 65535" }}{{ end -}}
{{- include "indi-allsky.validateBool" (dict "name" "web.ingress.enabled" "value" .Values.web.ingress.enabled) -}}
{{- include "indi-allsky.validateString" (dict "name" "web.ingress.className" "value" .Values.web.ingress.className "allowEmpty" true) -}}
{{- if not (kindIs "map" .Values.web.ingress.annotations) }}{{ fail "web.ingress.annotations must be a map/object" }}{{ end -}}
{{- if not (kindIs "slice" .Values.web.ingress.tls) }}{{ fail "web.ingress.tls must be a list of Ingress TLS objects" }}{{ end -}}
{{- if .Values.web.ingress.enabled -}}
  {{- include "indi-allsky.validatePattern" (dict "name" "web.ingress.host" "value" .Values.web.ingress.host "pattern" "^(\\*\\.)?[a-z0-9]([-a-z0-9.]*[a-z0-9])?$" "allowEmpty" false "description" "must be a lowercase DNS hostname, optionally wildcarded as *.example.com") -}}
{{- end -}}

{{/* --- edge PriorityClass ownership --------------------------------------- */}}
{{- $priorityClass := .Values.edge.priorityClass -}}
{{- include "indi-allsky.validateEnum" (dict "name" "edge.priorityClass.mode" "value" $priorityClass.mode "allowed" (list "create" "reference" "disabled")) -}}
{{- include "indi-allsky.validateEnum" (dict "name" "edge.priorityClass.preemptionPolicy" "value" $priorityClass.preemptionPolicy "allowed" (list "PreemptLowerPriority" "Never")) -}}
{{- include "indi-allsky.validateIntegerAtLeast" (dict "name" "edge.priorityClass.value" "value" $priorityClass.value "minimum" 1) -}}
{{/* Kubernetes' HighestUserDefinablePriority; above it the API server reserves
     the range for system-critical classes and rejects the object. */}}
{{- if gt (int $priorityClass.value) 1000000000 }}{{ fail "edge.priorityClass.value must be <= 1000000000 (Kubernetes reserves higher values for system-critical classes)" }}{{ end -}}
{{- include "indi-allsky.validateDnsSubdomain" (dict "name" "edge.priorityClass.name" "value" $priorityClass.name "objectKind" "PriorityClass name") -}}
{{- if eq $priorityClass.mode "reference" -}}
  {{- if not $priorityClass.name }}{{ fail "edge.priorityClass.name is required when edge.priorityClass.mode=reference — that mode uses a class owned by external IaC/CI and renders none itself" }}{{ end -}}
{{- else -}}
  {{- if $priorityClass.name }}{{ fail (printf "edge.priorityClass.name must be empty when edge.priorityClass.mode=%s — only reference mode names an externally owned class" $priorityClass.mode) }}{{ end -}}
{{- end -}}

{{/* --- edge devices, sensors and scheduling -------------------------------- */}}
{{- include "indi-allsky.validateBool" (dict "name" "edge.sensors.enabled" "value" .Values.edge.sensors.enabled) -}}
{{- include "indi-allsky.validateIntegerList" (dict "name" "edge.supplementalGroups" "value" .Values.edge.supplementalGroups "minimum" 0) -}}
{{- $devices := .Values.edge.devices -}}
{{- include "indi-allsky.validateHostPathList" (dict "name" "edge.devices.camera.hostPaths" "value" $devices.camera.hostPaths) -}}
{{- include "indi-allsky.validateHostPathList" (dict "name" "edge.devices.sensors.hostPaths" "value" $devices.sensors.hostPaths) -}}
{{- if not (kindIs "map" $devices.camera.resources) }}{{ fail "edge.devices.camera.resources must be a map/object of extended resource names to quantities" }}{{ end -}}
{{- if not (kindIs "map" $devices.sensors.resources) }}{{ fail "edge.devices.sensors.resources must be a map/object of extended resource names to quantities" }}{{ end -}}

{{- $sidecarIndiserver := eq .Values.indiserver.mode "sidecar" -}}
{{- if not $sidecarIndiserver -}}
  {{- if $devices.camera.hostPaths }}{{ fail "edge.devices.camera.hostPaths must be empty when indiserver.mode=external — the camera is attached to the external INDI server, not to this pod" }}{{ end -}}
  {{- if $devices.camera.resources }}{{ fail "edge.devices.camera.resources must be empty when indiserver.mode=external — the camera is attached to the external INDI server, not to this pod" }}{{ end -}}
{{- end -}}

{{- if eq $devices.mode "none" -}}
  {{- if or $devices.camera.hostPaths $devices.camera.resources }}{{ fail "edge.devices.camera.* must be empty when edge.devices.mode=none — set mode to hostpath or device-plugin to attach a camera" }}{{ end -}}
  {{- if or $devices.sensors.hostPaths $devices.sensors.resources }}{{ fail "edge.devices.sensors.* must be empty when edge.devices.mode=none — set mode to hostpath or device-plugin to attach sensors" }}{{ end -}}
  {{- if .Values.edge.sensors.enabled }}{{ fail "edge.sensors.enabled=true requires edge.devices.mode=hostpath or device-plugin — mode=none provides no sensor access mechanism" }}{{ end -}}
{{- else if eq $devices.mode "hostpath" -}}
  {{- if or $devices.camera.resources $devices.sensors.resources }}{{ fail "edge.devices.*.resources must be empty when edge.devices.mode=hostpath — extended resources are only scheduled in device-plugin mode" }}{{ end -}}
  {{- if and $sidecarIndiserver (not $devices.camera.hostPaths) (not $devices.sensors.hostPaths) }}{{ fail "edge.devices.mode=hostpath requires at least one entry in edge.devices.camera.hostPaths or edge.devices.sensors.hostPaths" }}{{ end -}}
  {{- if and .Values.edge.sensors.enabled (not $devices.sensors.hostPaths) }}{{ fail "edge.sensors.enabled=true with edge.devices.mode=hostpath requires edge.devices.sensors.hostPaths" }}{{ end -}}
{{- else -}}
  {{- if or $devices.camera.hostPaths $devices.sensors.hostPaths }}{{ fail "edge.devices.*.hostPaths must be empty when edge.devices.mode=device-plugin — host paths are only mounted in hostpath mode" }}{{ end -}}
  {{- if and $sidecarIndiserver (not $devices.camera.resources) }}{{ fail "edge.devices.mode=device-plugin requires edge.devices.camera.resources, e.g. {squat.ai/asi-camera: 1}" }}{{ end -}}
  {{- if and .Values.edge.sensors.enabled (not $devices.sensors.resources) }}{{ fail "edge.sensors.enabled=true with edge.devices.mode=device-plugin requires edge.devices.sensors.resources" }}{{ end -}}
{{- end -}}

{{- if and .Values.edge.supplementalGroups (ne $devices.mode "hostpath") -}}
  {{- fail "edge.supplementalGroups must be empty unless edge.devices.mode=hostpath — group ids only grant access to host device nodes" -}}
{{- end -}}
{{- if and $devices.sensors.hostPaths (not .Values.edge.sensors.enabled) -}}
  {{- fail "edge.devices.sensors.hostPaths requires edge.sensors.enabled=true — otherwise the mounts would be rendered and never used" -}}
{{- end -}}
{{- if and $devices.sensors.resources (not .Values.edge.sensors.enabled) -}}
  {{- fail "edge.devices.sensors.resources requires edge.sensors.enabled=true — otherwise the resource request would be scheduled and never used" -}}
{{- end -}}

{{/* --- capture scratch directory ------------------------------------------ */}}
{{/* A dedicated emptyDir at a path that overlaps the rendered config, the
     projected overlay, or the shared data volume would shadow that mount and
     silently discard whatever the pod expected to find there. */}}
{{- if .Values.edge.captureTmpDir -}}
  {{- $protected := list
        (include "indi-allsky.configPath" .)
        (include "indi-allsky.overlayMountPath" .)
        (include "indi-allsky.dataMountPath" .) -}}
  {{- $captureTmpDir := .Values.edge.captureTmpDir | trimSuffix "/" -}}
  {{- if eq $captureTmpDir "" }}{{ fail "edge.captureTmpDir must not be the filesystem root" }}{{ end -}}
  {{- range $path := $protected -}}
    {{- if or (eq $captureTmpDir $path) (hasPrefix (printf "%s/" $path) $captureTmpDir) (hasPrefix (printf "%s/" $captureTmpDir) $path) -}}
      {{- fail (printf "edge.captureTmpDir must not overlap %s" $path) -}}
    {{- end -}}
  {{- end -}}
{{- end -}}

{{- $sensitivePaths := list
  (list "FILETRANSFER" "PASSWORD")
  (list "S3UPLOAD" "SECRET_KEY")
  (list "MQTTPUBLISH" "PASSWORD")
  (list "SYNCAPI" "APIKEY")
  (list "PYCURL_CAMERA" "PASSWORD")
  (list "TEMP_SENSOR" "OPENWEATHERMAP_APIKEY")
  (list "TEMP_SENSOR" "WUNDERGROUND_APIKEY")
  (list "TEMP_SENSOR" "ASTROSPHERIC_APIKEY")
  (list "TEMP_SENSOR" "MQTT_PASSWORD")
  (list "DEVICE" "MQTT_PASSWORD")
  (list "LIBCAMERA" "MQTT_PASSWORD")
  (list "ADSB" "PASSWORD")
  (list "IMAGE_OVERLAY" "A_PASSWORD")
-}}
{{- range $path := $sensitivePaths -}}
  {{- $sectionName := index $path 0 -}}
  {{- $keyName := index $path 1 -}}
  {{- if hasKey $.Values.appConfig $sectionName -}}
    {{- $section := get $.Values.appConfig $sectionName -}}
    {{- if and (kindIs "map" $section) (hasKey $section $keyName) -}}
      {{- fail (printf "appConfig.%s.%s is credential-bearing and cannot be stored in a ConfigMap; configure it through the upstream UI after install" $sectionName $keyName) -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- end }}
