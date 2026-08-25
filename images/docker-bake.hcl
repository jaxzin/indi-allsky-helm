variable "REGISTRY" { default = "ghcr.io/jaxzin" }
variable "TAG"      { default = "dev" }
variable "INDI_CORE_VERSION"     { default = "v2.2.4.2" }
variable "INDI_3RDPARTY_VERSION" { default = "v2.2.4.1" }
variable "CAMERA_VENDOR"         { default = "supported" }

# Registry build cache (CI only; empty CACHE_REGISTRY disables caching for
# local builds). Cache refs embed the target name — <CACHE_REGISTRY>:<target>-
# <arch> — because a single shared ref would let each finishing target
# overwrite the previous target's cache export: indiserver exports after
# base, so base's expensive INDI compile would never stay cached. Every
# target — intermediates included — calls cache_from()/cache_to() with its
# own name; passing any other target's name re-introduces that overwrite.
variable "CACHE_REGISTRY" { default = "" } # e.g. ghcr.io/jaxzin/indi-allsky-cache
variable "CACHE_ARCH"     { default = "" } # amd64 | arm64
variable "CACHE_WRITE"    { default = "" } # "true" only on pushes to main

function "cache_from" {
  params = [target]
  result = CACHE_REGISTRY == "" ? [] : ["type=registry,ref=${CACHE_REGISTRY}:${target}-${CACHE_ARCH}"]
}

function "cache_to" {
  params = [target]
  result = CACHE_REGISTRY == "" || CACHE_WRITE != "true" ? [] : ["type=registry,ref=${CACHE_REGISTRY}:${target}-${CACHE_ARCH},mode=max"]
}

# Digest publishing (CI build jobs set PUSH_BY_DIGEST=true): buildx refuses
# to push-by-digest a target that still carries tags ("can't push tagged ref
# ... by digest"), so publish_tags() clears the tags and publish_output()
# carries the image name inside the output instead — the merge job attaches
# the real tags when it assembles the multi-arch manifest lists. Unset (local
# builds, bake --print lint job), targets keep their normal tags and default
# outputs. Every published target calls both helpers with its own name; the
# intermediates (`base`, `daemon-upstream`, `web-upstream`) call neither and
# are never pushed.
variable "PUSH_BY_DIGEST" { default = "" } # "true" in CI build jobs

function "publish_tags" {
  params = [target]
  result = PUSH_BY_DIGEST == "true" ? [] : ["${REGISTRY}/indi-allsky-${target}:${TAG}"]
}

function "publish_output" {
  params = [target]
  result = PUSH_BY_DIGEST != "true" ? [] : ["type=image,name=${REGISTRY}/indi-allsky-${target},push-by-digest=true,name-canonical=true,push=true"]
}

group "default" {
  targets = ["indiserver", "daemon", "web"]
}

# Intermediate INDI core build, consumed by later targets via the
# "indi.base" named context. Deliberately has no tags: it is never
# pushed under a friendly name.
target "base" {
  context    = "upstream"
  dockerfile = "docker/Dockerfile.indi_base_debian13"
  args = {
    TZ                = "UTC"
    INDI_CORE_VERSION = INDI_CORE_VERSION
  }
  cache-from = cache_from("base")
  cache-to   = cache_to("base")
}

target "indiserver" {
  context    = "upstream"
  dockerfile = "docker/Dockerfile.indiserver_debian13"
  contexts   = { "indi.base" = "target:base" }
  args = {
    INDI_3RDPARTY_VERSION = INDI_3RDPARTY_VERSION
    INDI_CAMERA_VENDOR    = CAMERA_VENDOR
  }
  labels = {
    "org.opencontainers.image.source"   = "https://github.com/jaxzin/indi-allsky-helm"
    "org.opencontainers.image.licenses" = "GPL-3.0-only"
  }
  cache-from = cache_from("indiserver")
  cache-to   = cache_to("indiserver")
  tags       = publish_tags("indiserver")
  output     = publish_output("indiserver")
}

# Upstream capture image. Consumes the "indi.base" named context (see
# upstream docker/Dockerfile.capture:1). Intermediate: cache helpers with its
# own name, no tags, no publish helpers — same discipline as `base`.
target "daemon-upstream" {
  context    = "upstream"
  dockerfile = "docker/Dockerfile.capture"
  contexts   = { "indi.base" = "target:base" }
  cache-from = cache_from("daemon-upstream")
  cache-to   = cache_to("daemon-upstream")
}

# Upstream gunicorn image. FROM python:3.13-slim — does NOT consume indi.base
# (upstream docker/Dockerfile.gunicorn:1). It DOES declare ARG TZ (consumed for
# /etc/localtime), so TZ must be passed. Dockerfile.capture declares no ARG TZ
# (TZ is baked by `base`), so daemon-upstream deliberately passes none.
target "web-upstream" {
  context    = "upstream"
  dockerfile = "docker/Dockerfile.gunicorn"
  args       = { TZ = "UTC" }
  cache-from = cache_from("web-upstream")
  cache-to   = cache_to("web-upstream")
}

target "daemon" {
  context    = "images"
  dockerfile = "daemon/Dockerfile"
  contexts   = { "daemon.upstream" = "target:daemon-upstream" }
  labels = {
    "org.opencontainers.image.source" = "https://github.com/jaxzin/indi-allsky-helm"
    # Deliberately differs from indiserver's plain "GPL-3.0-only": this image
    # also carries this repo's own Apache-2.0 entrypoint and config-rendering
    # scripts, which NOTICE records. The label and NOTICE must agree.
    "org.opencontainers.image.licenses" = "GPL-3.0-only AND Apache-2.0"
  }
  cache-from = cache_from("daemon")
  cache-to   = cache_to("daemon")
  tags       = publish_tags("daemon")
  output     = publish_output("daemon")
}

target "web" {
  context    = "images"
  dockerfile = "web/Dockerfile"
  contexts   = { "web.upstream" = "target:web-upstream" }
  labels = {
    "org.opencontainers.image.source" = "https://github.com/jaxzin/indi-allsky-helm"
    # As with daemon: this image ships this repo's Apache-2.0 scripts too.
    "org.opencontainers.image.licenses" = "GPL-3.0-only AND Apache-2.0"
  }
  cache-from = cache_from("web")
  cache-to   = cache_to("web")
  tags       = publish_tags("web")
  output     = publish_output("web")
}
