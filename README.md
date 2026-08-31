# indi-allsky-helm

A Helm chart and multi-arch container images for running
[indi-allsky](https://github.com/aaronwmorris/indi-allsky) by Aaron Morris on
any home Kubernetes cluster. All the interesting astronomy happens upstream —
this repo only packages it for Kubernetes.

## Status

Images first, chart under construction. All three container images build and
publish; the Helm chart is not yet published or installable. Watch the
releases for the first chart version.

## Images

Three multi-arch images, all running as uid/gid 10001 with `sudo` purged
rather than merely disarmed.

| Image | Purpose | Entrypoint |
| --- | --- | --- |
| `ghcr.io/jaxzin/indi-allsky-indiserver` | INDI server and camera drivers, run as a sidecar next to capture | upstream `start_indiserver.sh` |
| `ghcr.io/jaxzin/indi-allsky-daemon` | the capture and processing daemon | `entrypoint-daemon.sh` — renders the config, waits for the schema and initial configuration, then execs `allsky.py` |
| `ghcr.io/jaxzin/indi-allsky-web` | the gunicorn web UI, and the migration tooling the chart runs as an initContainer | `entrypoint-web.sh`; `migrate.sh` for migrations, bootstrap and seeding |

The `daemon` and `web` images are overlays on upstream's own container images:
they replace the entrypoints with ones suited to Kubernetes — no fixed startup
sleeps, no `sudo chown`, no migrations during web startup — and drive auth and
database settings from the environment.

Smoke tests:

```sh
# web: the venv interpreter and the checkout as cwd are both part of the
# contract — a bare `--entrypoint python3` hits the system interpreter and fails
docker run --rm -w /home/allsky/indi-allsky \
  --entrypoint /home/allsky/venv/bin/python3 \
  ghcr.io/jaxzin/indi-allsky-web:main -c "import indi_allsky; print('ok')"

# daemon and indiserver: check the published entrypoint and user without
# starting hardware-dependent processes
docker image inspect ghcr.io/jaxzin/indi-allsky-daemon:main \
  --format '{{.Config.User}} {{json .Config.Entrypoint}}'
docker image inspect ghcr.io/jaxzin/indi-allsky-indiserver:main \
  --format '{{.Config.User}} {{json .Config.Entrypoint}}'
```

The full interface — paths, the environment-variable contract, the chart's
hard requirements, migration behaviour and config-overlay semantics — is in
[docs/container-contract.md](docs/container-contract.md). Chart values and
database/credential mode examples are in
[docs/configuration.md](docs/configuration.md).
Before production use, read its credential-lifecycle, storage-lifecycle,
backup-protection, and restore sections: changing a Kubernetes Secret does not
rotate an initialized MariaDB account, retained PVCs are a coherent recovery
set, and compressed SQL dumps are not encrypted recovery sets by themselves.

## Upstream pin model

- `UPSTREAM_VERSION` holds the upstream release tag being packaged. It is the
  **only** place the tag lives — workflows, the Makefile, and image tags all
  read it from this file.
- `UPSTREAM_SHA` holds the commit SHA that tag pointed to at pin time. Git
  tags are mutable, so the SHA — not the tag — is the trust anchor:
  `make upstream` refuses to build if the checked-out tag no longer resolves
  to the pinned SHA.
- `patches/` contains any patches applied on top of the upstream checkout
  (see `patches/README.md` for the rules).

`make upstream` clones the pinned tag into `upstream/`, verifies the SHA, and
applies the patches. The `upstream/` directory is never vendored into this
repo — it is gitignored and recreated on every build.

### Re-pinning

To move to a new upstream release, update **both** files together in one PR:

```sh
TAG="$(cat UPSTREAM_VERSION)"   # after editing UPSTREAM_VERSION to the new tag
git ls-remote https://github.com/aaronwmorris/indi-allsky.git \
  "refs/tags/${TAG}" "refs/tags/${TAG}^{}" | tail -n1 | cut -f1 > UPSTREAM_SHA
```

The two-pattern form with `tail -n1` is deliberate: for an annotated tag the
peeled `^{}` line carries the commit SHA, while a lightweight tag only
produces the plain line. Either way the last line is the commit the tag
points to. Reviewers of a re-pin PR must re-run this command independently —
the Makefile gate only proves `UPSTREAM_VERSION` and `UPSTREAM_SHA` agree
with each other, not that they match upstream.

## Licensing

The code in this repository (chart, build tooling, entrypoints) is licensed
under [Apache-2.0](LICENSE). The container images it builds ship
indi-allsky, which is GPL-3.0 — each image contains the corresponding
upstream source at the pinned tag plus the `patches/` directory. See
[NOTICE](NOTICE) for the corresponding-source statement.

## Build model

- `make upstream` — checkout the pinned upstream tag into `upstream/`,
  verify `UPSTREAM_SHA`, apply `patches/`.
- `docker buildx bake -f images/docker-bake.hcl` — build the bake group
  `default`: `indiserver`, `daemon` and `web`. Four further targets —
  `base`, `indiserver-upstream`, `daemon-upstream` and `web-upstream` — are
  untagged intermediates consumed through buildx named contexts and never
  published. Seven targets in total; each published image is this repository's
  own overlay on the matching intermediate.
- `make image-contract` — assert the build-graph shape and the image sources
  without building or pulling anything. `images/tests/image-contract.sh` also
  offers `--runtime-contract` and `--all`, which inspect images that already
  exist locally and never fetch one, and `--build-runtime-contract`, the only
  mode that builds the current checkout first.
- `make lint` — hadolint, shellcheck and actionlint, all strict. Needs
  `docker` (hadolint runs from the same digest-pinned image CI uses, so a
  clean local run means a clean CI run), plus `shellcheck` and `actionlint`
  on `PATH`.
- CI builds each architecture natively (`linux/amd64` on `ubuntu-24.04`,
  `linux/arm64` on `ubuntu-24.04-arm` — no QEMU for the INDI compile),
  pushes by digest, then merges the per-arch digests into multi-arch
  manifest lists.
- Published images: `ghcr.io/jaxzin/indi-allsky-indiserver`,
  `ghcr.io/jaxzin/indi-allsky-daemon` and `ghcr.io/jaxzin/indi-allsky-web`,
  each tagged `main` and with the contents of `UPSTREAM_VERSION`; platforms
  `linux/amd64,linux/arm64`.
- CI keeps its registry build cache in the `ghcr.io/jaxzin/indi-allsky-cache`
  GHCR package (one tag per target and architecture); only authenticated CI
  reads or writes it, so it stays private.

## Node contract

The chart pins capture to your camera hardware through two node labels; every
other workload (web UI, database, optional MQTT) floats on ordinary cluster
compute.

- `indi-allsky.io/camera: "true"` — this node has the all-sky camera attached.
  Manual labeling is the baseline; optional autodiscovery of USB cameras via
  Node Feature Discovery is available through the `discovery.nfd.*` values.
- `indi-allsky.io/sensors: "true"` — this node is wired to environmental
  sensors (GPIO / i2c / SPI / 1-wire). Always applied manually: physical
  wiring cannot be autodiscovered.

**Neither label is required by default.** `edge.devices.mode` defaults to
`none`, which runs the INDI simulator: the edge pod schedules anywhere, mounts
no host device, and runs no privileged container. A label requirement appears
only where it is real — the camera label when `edge.devices.mode: hostpath`
supplies a local camera, and the sensors label when hostPath sensors are
enabled. `device-plugin` mode uses extended resources instead and needs
neither.

**v1 constraint:** camera and sensors must be on the **same node**. Upstream
indi-allsky runs capture, sensing, and processing as one multiprocess
application coordinating over shared memory, so the chart schedules them as a
single edge pod.

The chart is hardened by default: every container runs under a restricted
security context, and no pod mounts a service-account token. Exactly one
container can become privileged, and only when you ask for it —
`indiserver` with `edge.devices.mode: hostpath` and a local camera. It stays
uid 10001 even then.

Details: [docs/node-contract.md](docs/node-contract.md), alongside the
[container contract](docs/container-contract.md),
[chart configuration](docs/configuration.md) and
[topologies](docs/topologies.md) — sidecar vs external indiserver, NFD camera
autodiscovery, and the optional MQTT broker.

A worked example of a ZWO camera on a Raspberry Pi, with sensors, NFS storage,
autodiscovery and the broker, is in
[examples/values-zwo-pi.yaml](examples/values-zwo-pi.yaml).
