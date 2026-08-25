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
{{- $rendered := toString .value -}}
{{- if not (regexMatch "^[0-9]+$" $rendered) -}}
  {{- fail (printf "%s must be a whole number >= %d" .name (int .minimum)) -}}
{{- end -}}
{{- if lt (int $rendered) (int .minimum) -}}
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

{{- include "indi-allsky.validatePattern" (dict "name" "externalDatabase.charset" "value" .Values.externalDatabase.charset "pattern" $charsetPattern "allowEmpty" false "description" "may contain only letters, digits, and underscore") -}}
{{- include "indi-allsky.validatePattern" (dict "name" "externalDatabase.collation" "value" .Values.externalDatabase.collation "pattern" $charsetPattern "allowEmpty" false "description" "may contain only letters, digits, and underscore") -}}
{{- include "indi-allsky.validatePattern" (dict "name" "edge.captureTmpDir" "value" .Values.edge.captureTmpDir "pattern" "^/.*" "allowEmpty" true "description" "must be an absolute path when set") -}}
{{- include "indi-allsky.validateSecretName" (dict "name" "credentials.existingSecret" "value" .Values.credentials.existingSecret) -}}
{{- include "indi-allsky.validateSecretName" (dict "name" "mariadb.rootCredentials.existingSecret" "value" .Values.mariadb.rootCredentials.existingSecret) -}}
{{- include "indi-allsky.validateDnsSubdomain" (dict "name" "storage.data.existingClaim" "value" .Values.storage.data.existingClaim "objectKind" "PersistentVolumeClaim name") -}}

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
