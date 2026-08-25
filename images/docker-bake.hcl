variable "REGISTRY" { default = "ghcr.io/jaxzin" }
variable "TAG"      { default = "dev" }
variable "INDI_CORE_VERSION"     { default = "v2.2.4.2" }
variable "INDI_3RDPARTY_VERSION" { default = "v2.2.4.1" }
variable "CAMERA_VENDOR"         { default = "supported" }

# Registry build cache (CI only; empty CACHE_REGISTRY disables caching for
# local builds). Cache refs embed the target name — <CACHE_REGISTRY>:<target>-
# <arch> — because a single shared ref would let each finishing target
# overwrite the previous target's cache export: indiserver exports after
# base, so base's expensive INDI compile would never stay cached. New
# targets (A3: daemon, web) inherit the scheme by calling
# cache_from()/cache_to() with their own name.
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

group "default" {
  targets = ["indiserver"] # A3 appends "daemon", "web"
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
  tags       = ["${REGISTRY}/indi-allsky-indiserver:${TAG}"]
}
