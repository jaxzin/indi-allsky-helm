variable "REGISTRY" { default = "ghcr.io/jaxzin" }
variable "TAG"      { default = "dev" }
variable "INDI_CORE_VERSION"     { default = "v2.2.4.2" }
variable "INDI_3RDPARTY_VERSION" { default = "v2.2.4.1" }
variable "CAMERA_VENDOR"         { default = "supported" }

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
  tags = ["${REGISTRY}/indi-allsky-indiserver:${TAG}"]
}
