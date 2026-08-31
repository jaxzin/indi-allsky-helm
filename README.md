# indi-allsky-helm

A Helm chart and multi-arch container images for running
[indi-allsky](https://github.com/aaronwmorris/indi-allsky) by Aaron Morris on
any home Kubernetes cluster. All the interesting astronomy happens upstream —
this repo only packages it for Kubernetes.

Capture is pinned to the node your camera is plugged into. Everything else —
web UI, database, the optional MQTT broker — floats on ordinary cluster
compute.

## Quickstart

You need a Kubernetes cluster (1.26+) and a `ReadWriteMany` storage class. You
do **not** need a camera to try it: the default values run the INDI simulator,
schedule anywhere, mount no host device, and run no privileged container.

```sh
# A throwaway credential Secret — see docs/configuration.md for the real thing.
# INDIALLSKY_FLASK_PASSWORD_KEY is a Fernet key — 32 random bytes, url-safe
# base64 — and it is what decrypts stored application passwords. Keep it.
# Replace your-rwx-storageclass below; the chart rejects a name that is not a
# valid DNS subdomain, so the placeholder has to be lowercase.
kubectl create namespace allsky
kubectl -n allsky create secret generic indi-allsky-env \
  --from-literal=INDIALLSKY_FLASK_SECRET_KEY="$(openssl rand -hex 32)" \
  --from-literal=INDIALLSKY_FLASK_PASSWORD_KEY="$(openssl rand -base64 32 | tr '+/' '-_')" \
  --from-literal=MARIADB_PASSWORD="$(openssl rand -hex 16)" \
  --from-literal=INDIALLSKY_WEB_PASS="$(openssl rand -hex 16)"
kubectl -n allsky create secret generic indi-allsky-mariadb-root \
  --from-literal=MARIADB_ROOT_PASSWORD="$(openssl rand -hex 16)"

helm install allsky oci://ghcr.io/jaxzin/charts/indi-allsky \
  --version 0.1.0 --namespace allsky \
  --set credentials.existingSecret=indi-allsky-env \
  --set mariadb.rootCredentials.existingSecret=indi-allsky-mariadb-root \
  --set adminUser.username=admin \
  --set storage.data.storageClassName=your-rwx-storageclass

kubectl -n allsky port-forward svc/allsky-indi-allsky-web 8080:8080
# then http://localhost:8080/indi-allsky
```

> The first chart version is not published yet — see
> [project status](#project-status) below. Until it is, install from a git
> checkout: `helm install allsky ./charts/indi-allsky …`.

For a real camera, copy
[`examples/values-zwo-pi.yaml`](examples/values-zwo-pi.yaml) and read
[docs/host-prep.md](docs/host-prep.md) first. For GitOps, start from
[`examples/argocd-application.yaml`](examples/argocd-application.yaml) or
[`examples/flux-helmrelease.yaml`](examples/flux-helmrelease.yaml).

## Values you will actually set

`values.yaml` is the full reference and every key is commented. These are the
ones almost every install touches.

| Value | Default | Why you care |
| --- | --- | --- |
| `image.digests.{indiserver,daemon,web}` | `""` | **The production pinning path.** Each release publishes the digests it was tested against. Empty means mutable tags under `IfNotPresent`, so a cached node and a fresh node can diverge. |
| `storage.data.storageClassName` | `""` (cluster default) | Must be `ReadWriteMany`: edge is pinned to the camera node, web is not. |
| `storage.retentionPolicy` | `Retain` | Keeps both PVCs — the image archive **and** the database — across an uninstall. |
| `credentials.existingSecret` | `""` | Your Secret with the Flask keys and the database password. Inline values exist for development only. |
| `mariadb.rootCredentials.existingSecret` | `""` | Separate, never mounted into an application workload, and recovery material a schema dump does not contain. |
| `mariadb.enabled` / `externalDatabase.*` | `true` / unset | In-chart single-node MariaDB, or point at your own server. |
| `mariadb.backup.enabled` | `false` | Scheduled `mariadb-dump` to the data volume, with its own retention. |
| `oidc.enabled`, `oidc.discoveryEndpoint` | `false` | Upstream's native OIDC. `oidc.localAuth: false` removes the local login form. |
| `adminUser.username` | `""` | Seeds one local admin, and only on a database with no real user yet. |
| `edge.devices.mode` | `none` | `none` (simulator), `device-plugin` (preferred for hardware), `hostpath` (explicit opt-in). |
| `edge.supplementalGroups` | `[]` | The gids that let uid 10001 open your device nodes. Node state — read them off the node. |
| `edge.sensors.enabled` | `false` | Adds the sensors label to the node selector and mounts sensor devices. |
| `indiserver.ccdDriver` | `indi_simulator_ccd` | `indi_asi_ccd`, `indi_qhy_ccd`, … |
| `indiserver.mode` | `sidecar` | `external` points the daemon at an indiserver this chart does not manage. |
| `web.ingress.*` | disabled | One host, your class name and annotations, optional TLS. |
| `appConfig` | `{}` | GitOps-owned upstream settings, deep-merged over the app's database config on every deploy. |
| `timezone` | `UTC` | Timestamps and capture scheduling. |

## Documentation

| | |
| --- | --- |
| [docs/host-prep.md](docs/host-prep.md) | What the node OS has to provide: dtoverlays, udev rules, group ids, `nfs-common`. Read before real hardware. |
| [docs/node-contract.md](docs/node-contract.md) | The two labels, the same-node constraint, scheduling postures, and exactly what "privileged" does and does not grant here. |
| [docs/topologies.md](docs/topologies.md) | The v1 picture, sidecar vs external indiserver, NFD autodiscovery, the optional broker, and what is not built yet. |
| [docs/configuration.md](docs/configuration.md) | Every mode choice and the fail-fast rules — plus the credential, storage, backup and restore lifecycle. |
| [docs/container-contract.md](docs/container-contract.md) | The image interface: paths, environment, migration behaviour, overlay semantics. Only needed if you run the images without the chart. |

## Before you run this for real

Four contracts that are easy to discover the hard way. Each is covered in full
in [docs/configuration.md](docs/configuration.md); this is the short version.

- **Changing a Kubernetes Secret does not rotate a MariaDB account.** The
  initialization variables apply only while `/var/lib/mysql` is empty, so both
  the application and root credentials become database state on first start.
  Editing the Secret afterwards breaks the login rather than rotating it.
  Rotation is one coordinated change: update the database-side account, then
  the Secret, then roll the workloads.
- **The chart renders no restore Job and no root-recovery Job.** Both
  procedures are operator-run, in a maintenance window. Keep the root Secret:
  an application-schema dump contains no root credentials, system tables or
  grants, and a lost root password cannot be reset by setting a new Secret
  value while a populated datadir survives.
- **Both PVCs belong to exactly one release.** The database datadir and the
  shared application volume are one coherent recovery set: neither images
  without a matching database nor a database without its migration history is
  a recovery. Do not share or rebind either claim across releases.
- **`.sql.gz` dumps are compressed, not encrypted.** Encryption at rest,
  transport, and off-cluster retention belong to your storage and your backup
  automation. A usable recovery set is the dump *plus* the application Secret
  (especially the Fernet password key), the Alembic history, and the image
  archive.

The restore procedure is not untested prose: `e2e/verify-restore.sh` runs it
end to end against a live release in CI, on every change to the chart or the
images — quiesce, dump, drop,
recreate, restore, restart, then require the application to decrypt its
configuration and serve the restored catalogue, including the truncated-dump
and missing-history failure paths
([PR #40](https://github.com/jaxzin/indi-allsky-helm/pull/40)).

And one that is not about data: **the image archive is served
unauthenticated**, regardless of `web.authAllViews`. nginx serves it directly
off the volume, so those requests never reach Flask and never see the
application's auth. Gate it at the ingress if the archive should be private.

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
[docs/container-contract.md](docs/container-contract.md).

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

**A re-pin is gated.** No `UPSTREAM_VERSION` bump merges until
[issue #9](https://github.com/jaxzin/indi-allsky-helm/issues/9) closes — see
[roadmap](#roadmap).

## Node contract

The chart pins capture to your camera hardware through two node labels; every
other workload floats on ordinary cluster compute.

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
uid 10001 even then, which grants it **no** capabilities: device access
depends entirely on the node's own permissions. That is the single most common
cause of a camera that works bare-metal and fails in the pod —
[docs/host-prep.md](docs/host-prep.md) covers it.

Details: [docs/node-contract.md](docs/node-contract.md).

## Project status

**v1, first release pending.** Everything below is built, tested in CI, and
described in the docs above:

- the edge topology — indiserver sidecar plus daemon, pinned by node label,
  with `hostpath`, `device-plugin` and simulator device modes and an
  `indiserver.mode: external` escape hatch;
- the web tier — gunicorn bound to loopback behind an nginx sidecar, with a
  migration initContainer, config-overlay barrier, and optional Ingress;
- internal MariaDB or an external database, a separate recoverable root
  credential, verified atomic pre-migration and scheduled dumps, and a
  serialized maintenance path;
- native OIDC, an optional seeded local admin, and default-on ingress
  NetworkPolicies;
- an optional MQTT broker and NFD camera autodiscovery;
- multi-arch `linux/amd64` + `linux/arm64` images from a SHA-pinned upstream
  ref, and an end-to-end kind gate covering the capture pipeline, runtime
  policy enforcement, node placement, the overlay barrier, migration paths and
  the backup/restore procedure.

Not yet published: the chart itself. The release workflow is in place
(`.github/workflows/release.yml`); pushing `chart-v0.1.0` packages the chart,
pushes it to `oci://ghcr.io/jaxzin/charts`, and records the commit SHA and the
three image digests in the release notes.

### Roadmap

- **Migration hardening — [#9](https://github.com/jaxzin/indi-allsky-helm/issues/9),
  and a hard gate.** v1 keeps upstream's runtime `flask db revision
  --autogenerate`, guarded by a verified pre-migration dump. That is a
  deliberate temporary compromise: runtime-generated DDL has no reviewed diff.
  #9 commits Alembic revisions in CI, makes runtime upgrade-only, adds a
  migration-completion identity independent of the overlay checksum, and adds
  an N→N+1 upgrade e2e. **No `UPSTREAM_VERSION` bump merges before it closes.**
- **Video-worker extraction (phase 2).** Timelapse and keogram generation
  currently runs on the camera node. VideoWorker is the most separable piece of
  upstream's daemon — database `taskqueue` driven, with only its wake-up
  in-process — so a small patch lets it run as a floating Deployment behind
  `videoWorker.mode: embedded|cluster`. The patch is an **upstream PR
  candidate**, not a permanent fork. See
  [docs/topologies.md](docs/topologies.md#topologies-that-do-not-exist-yet).
- **Documented but unbuilt:** a full capture split (thin indiserver on the
  camera node, daemon floating) and a syncapi web-only recipe for operators
  without RWX storage. Both are described in
  [docs/topologies.md](docs/topologies.md#topologies-that-do-not-exist-yet).
- **Not planned for v1:** multi-camera, HA MariaDB, first-class libcamera/CSI
  support.

Open work lives in the
[issue tracker](https://github.com/jaxzin/indi-allsky-helm/issues); the
historical design record is
[docs/planning/design-spec.md](docs/planning/design-spec.md).

## Licensing

The code in this repository (chart, build tooling, entrypoints) is licensed
under [Apache-2.0](LICENSE). The container images it builds ship
indi-allsky, which is GPL-3.0 — each image contains the corresponding
upstream source at the pinned tag plus the `patches/` directory. See
[NOTICE](NOTICE) for the corresponding-source statement.

This project is not affiliated with or endorsed by upstream. Bugs in
indi-allsky itself belong
[upstream](https://github.com/aaronwmorris/indi-allsky/issues); bugs in the
chart, the images or the docs belong here.

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

### Releasing

Chart releases are cut by pushing an annotated tag `chart-v<semver>` at the
commit to publish. `.github/workflows/release.yml` then refuses the tag if it
disagrees with `Chart.yaml`, resolves the three image digests out of the
registry, packages and pushes the chart to `oci://ghcr.io/jaxzin/charts`,
verifies it is pullable, and opens a GitHub Release recording the commit SHA
and those digests alongside GitHub's generated change list. Nothing about a
release is typed into a form.
