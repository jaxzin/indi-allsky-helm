# indi-allsky on Kubernetes — deployment design

> **Provenance:** migrated 2026-08-25 from the author's private planning workspace, with operator-specific details (private hostnames, internal repo and service names) genericized. The live execution record is this repository's issue tracker (issues #1–#10); this is a historical design record, not living documentation.

> **Status (2026-08-25):** approved and in execution — see the Execution status section of the [implementation plan](implementation-plan.md) and this repo's issue tracker for the live record.

Date: 2026-08-20
Status: awaiting review
Home: authored 2026-08-20 in the author's private planning workspace; migrated to `jaxzin/indi-allsky-helm` 2026-08-25 (this copy).

## Summary

An open-source Helm chart (`indi-allsky`) in a new public repo `jaxzin/indi-allsky-helm` that deploys [indi-allsky](https://github.com/aaronwmorris/indi-allsky) onto any home Kubernetes cluster, with a documented node-demarcation contract: the camera/sensor node runs only capture and sensing, every other workload floats on cluster compute, and capture is scheduling-protected on its node. First instance: the operator's k3s homelab cluster, where the camera node is already a k3s agent running indi-allsky bare-metal.

No prior art exists — no Helm chart or k8s manifests for indi-allsky anywhere. Upstream is container-friendly (official multi-service docker-compose; maintainer calls remote-indiserver topologies "entirely supported" in discussion #1259) but publishes no images and has no CI.

## Goals

1. Publishable chart any home k8s operator can use; clear docs on how physical nodes are demarcated (labels, host prep, device access).
2. Capture and sensor handling pinned to the correctly-labeled node(s); everything else floats.
3. Capture is protected on its node; surplus node capacity is usable by the rest of the cluster (share-with-protection posture supported; dedicated-taint posture also supported).
4. Heavy compute (timelapse/keogram/star-trail generation) movable off the camera node — phased in via a small upstream-able patch.
5. Working deployment on the operator's cluster replacing the bare-metal install.

## Non-goals (v1)

- Multi-camera support, HA MariaDB, first-class libcamera/CSI camera support (escape hatch: `indiserver.mode: external` pointing at a host-run indiserver), syncapi web-only replication recipe (documented as a future topology), focuser support when the web pod is off the camera node (upstream runs focuser moves inside gunicorn; documented limitation).

## Constraints from the codebase (verified 2026-08-20)

- The `allsky.py` daemon is one inseparable process group: Capture, Image, Video, Sensor workers communicate via `multiprocessing.Array` shared memory (auto-exposure feedback loop, sensor readings, day/night state) and local tempfile handoff (`camera/indi.py:388-431`). Cannot split across nodes without code changes.
- Clean seams: indiserver (TCP, `INDI_SERVER`/`INDI_PORT`), the database (MariaDB proven on upstream's docker path), the web UI (couples to the daemon only via DB rows polled every 13 s + the shared image folder), MQTT, syncapi.
- SensorWorker (i2c/1-wire/GPIO, dew-heater/fan control loop) has no network transport → sensors must be on the daemon's node. VideoWorker is the most separable (DB `taskqueue` driven; only its wake-up is an in-process queue).
- Native OIDC auth exists (authlib): `OIDC_ENABLE`, discovery endpoint, PKCE, `OIDC_USERNAME_CLAIM`, `OIDC_ALLOWED_GROUPS`/`OIDC_ADMIN_GROUPS`, refresh-token handling; default scopes include `offline_access` (`flask.json_template:44-58`, `indi_allsky/flask/__init__.py:130-210`).
- Upstream publishes no container images and has no CI; compose builds locally with unqualified names; webserver/mosquitto images bake TLS+passwords at build time; migrations run in the gunicorn entrypoint (unsafe >1 replica); container user has passwordless sudo. All replaced/fixed in the chart's image pipeline.
- Upstream ships simulator camera interfaces (`test_*`, `indi_simulator_ccd`) → full pipeline testable in CI without hardware.

## Decisions log

| Decision | Choice |
|---|---|
| Deliverable | Standalone public repo `jaxzin/indi-allsky-helm`, chart name `indi-allsky`; the operator's homelab consumes it as one instance |
| Topology | v1: full daemon pinned to camera node ("edge"), services float. Phase 2: VideoWorker extracted to a floating Deployment behind `videoWorker.mode: embedded\|cluster` via a fork patch (upstream PR candidate) |
| Image-folder sharing | RWX PVC required by chart; the operator's instance: NFS from a NAS via csi-driver-nfs |
| Database | Chart-optional single-node MariaDB (StatefulSet) or `externalDatabase.*`; migrations as a Helm hook Job |
| Auth (operator's instance) | Native OIDC against the operator's OIDC IdP before cutover (no interim app-local login) |
| Migration | Fresh MariaDB; copy image tree to NFS; old SQLite kept as backup; B2 remains the historical archive; no cross-engine data migration |
| Camera-node posture at cutover | Keep the existing `example.com/dedicated=allsky:NoSchedule` taint for burn-in; drop later to enable surplus-compute sharing |
| Operator hardware | ZWO ASI676MC on USB3 (indi_asi_ccd); i2c env sensor + DS18x20 1-wire + GPIO actuators (dew heater/fan), all on the same node as the camera |

## Architecture

### Workloads (chart-rendered)

| Workload | Kind / placement | Contents |
|---|---|---|
| `edge` | Deployment, replicas=1, strategy Recreate, nodeSelector on the camera label | Pod with 2 containers: **indiserver** (owns camera USB device; the only container with camera device access) and **daemon** (`allsky.py`: capture/image/video/sensor/upload workers; `INDI_SERVER=localhost`; sensor device mounts; tempfile handoff in an emptyDir private to the container). |
| `web` | Deployment, floats | **gunicorn** (Flask) + **nginx** sidecar serving `/indi-allsky/images` (RWX PVC) and static assets, proxying app routes to gunicorn (adapted from upstream `service/nginx_indi-allsky.conf`). Ingress with configurable host/annotations; TLS is the cluster's concern. |
| `mariadb` | StatefulSet, optional (`mariadb.enabled`), local PV, optional node pinning | Official `mariadb` image; or `externalDatabase.*` (host/port/name/user + existingSecret). |
| `migrations` | initContainer on the (single-replica) web Deployment | `flask db upgrade` + `config.py bootstrap` + config-overlay seeding — removed from the gunicorn entrypoint. (A pre-install hook Job would deadlock waiting on the in-chart MariaDB, which hooks precede; the initContainer preserves upstream's web-migrates-first ordering. Alembic revisions are runtime-generated upstream, so the migration folder persists on the data PVC.) |
| `mosquitto` | Deployment, optional, default disabled | Most homelabs have a broker; app config points at any broker. |
| `video-worker` (phase 2) | Deployment, floats, `videoWorker.mode: cluster` | Patched daemon image running only the VideoWorker, polling the DB `taskqueue` instead of the in-process `video_q` nudge. Mounts the RWX image PVC. |
| NFD rule | optional (`discovery.nfd.enabled`) | NodeFeatureRule labeling nodes by astro-camera USB vendor IDs (ZWO `03c3`, QHY `1618`, …). |

Shared state: one RWX PVC (`accessModes: [ReadWriteMany]` required; storageClass configurable) for the image folder, mounted by edge (RW), web (RO — nothing in the web tier writes images; revisit only if a future feature like syncapi-receive needs it), video-worker (RW). MariaDB reachable from edge + web + video-worker.

### Node-demarcation contract (the public interface)

- `indi-allsky.io/camera: "true"` — node with the camera attached. Manual labeling is the documented baseline; optional NFD rule autodiscovers USB astro cameras.
- `indi-allsky.io/sensors: "true"` — node with GPIO/i2c/SPI/1-wire sensor hardware. **Always manual** (physical wiring is not discoverable).
- v1 constraint stated plainly in the README: camera and sensors must be the same node (upstream process model). Edge pod nodeSelector requires the camera label, plus the sensors label when sensors are enabled.
- Host prep is out of the chart's scope but documented as prerequisites: i2c enabled, `w1-gpio` dtoverlay for 1-wire, camera udev rules, container runtime access to `/dev`. On the operator's fleet this lives in a host-provisioning repo in their private GitOps infrastructure, per that fleet's boundary rules.
- Device access, values-selectable per device group:
  - `devices.mode: device-plugin` (recommended): [squat/generic-device-plugin] resources for USB (by vendor/product), i2c, gpiochip — unprivileged pods.
  - `devices.mode: hostpath`: privileged containers + hostPath mounts (`/dev/bus/usb`, `/dev/i2c-*`, `/dev/gpiochip*`, `/sys/bus/w1`) — parity with upstream compose, always works.

### Scheduling & capture protection

- PriorityClass `indi-allsky-capture` (high value, preempting) on the edge pod; Guaranteed QoS (requests == limits) so kubelet pressure never evicts capture. Chart README documents the share-with-protection posture: other workloads may schedule onto the camera node and are preempted/outranked, never the reverse.
- `dedicatedNode.*` values render tolerations (and docs for the matching taint) for operators who prefer an exclusive node. The operator's instance starts in this posture (existing taint `example.com/dedicated=allsky:NoSchedule`), moving to share-with-protection after burn-in.
- Video generation inherits upstream's `nice 19` inside the edge pod in v1; phase 2 moves it off-node entirely.

### Config & secrets

- `flask.json` rendered from a ConfigMap + Secret (secret key, DB URI/creds, OIDC client secret) — replaces the entrypoint jq templating. App config (cameras, exposures, uploads, MQTT) lives in the DB as upstream intends; chart provides an optional one-shot config-import Job (`config.py load`) for config-as-code seeding.
- The operator's instance: ExternalSecrets from the operator's secret store (DB creds, Flask secret key, OIDC creds, B2 creds).

### Auth

- Chart: `oidc.*` values map to the app's native `OIDC_*` settings (enable, provider name, client id/secret via existingSecret, discovery endpoint, groups→role mapping, PKCE). App-local login remains upstream's default when OIDC is disabled.
- The operator's instance (before cutover): register the provider in the operator's OIDC IdP with the **complete field set** — `offline_access` in the scope selector plus both token-validity fields — because the app requests `offline_access` by default and implements refresh. The IdP's explicit-consent flow requirement and sliding-session lifetime policy apply. `OIDC_ADMIN_GROUPS: [homelab-admins]`, `OIDC_ALLOWED_GROUPS: [homelab-users]`; the discovery endpoint is sourced from the provider registration's output, never restated by hand.

### Image build pipeline (prerequisite workstream)

- GitHub Actions in `jaxzin/indi-allsky-helm`: buildx multi-arch (arm64 + amd64) images — `ghcr.io/jaxzin/indi-allsky-indiserver`, `-daemon`, `-web` — from a **pinned upstream release ref** plus a `patches/` directory (phase-2 video-worker patch lives here until upstreamed; public CI cannot reach the operator's private fork).
- Cleanups vs upstream Dockerfiles: no build-time TLS/passwords, no passwordless sudo (fsGroup/initContainer ownership instead), multi-stage instead of compose `additional_contexts`, migrations out of entrypoints.
- Chart published to ghcr as an OCI Helm chart; repo also carries example ArgoCD `Application` and Flux `HelmRelease` manifests.

## Phases

1. **v1 (chart + the operator's cutover):** edge daemon topology, web/DB floating, NFS RWX, native OIDC, CI with simulator e2e. Zero upstream code changes.
2. **Phase 2:** video-worker extraction (fork patch → upstream PR), `videoWorker.mode: cluster`, heavy compute floats.
3. **Documented ceiling (not built):** full capture split (thin indiserver on the camera node, daemon floats) for sensor-less or MQTT-sensor setups.

## First instance — platform changes & cutover (operator's cluster)

*(This section summarizes the operator's private deployment plan; details of that infrastructure are genericized here.)*

1. Platform prerequisites (each its own PR/verification): an NFS CSI driver + NFS storageClass on the cluster; the NAS's NFS export needs an infrastructure-as-code home (no manual NAS-console step; tracked as an open item); OIDC provider registration in the IdP's config repo; secret-store paths + ExternalSecrets.
2. A child ArgoCD Application in the operator's cluster repo → `jaxzin/indi-allsky-helm` at a pinned revision + instance values (tolerating the dedicated-node taint; nodeSelector labels applied to the camera node via the cluster repo's configuration management, where labels/taints already live).
3. Cutover (camera is exclusively claimed, so this is a stop-the-world window): stop the bare-metal services; export app config (`config.py dump`); copy the image tree to the NFS share; deploy; import config; verify capture/sensors/dew-heater loop, OIDC login (admin + non-member denial), B2 uploads, MQTT telemetry into the operator's home-automation stack.
4. Retirements after verification: the interim ingress pattern that fronted the bare-metal install, and the host's Apache/gunicorn/systemd units; the host-provisioning repo shrinks to host prep (dtoverlays, udev, k3s join/labels). Old SQLite retained as backup.
5. Update the operator's internal service documentation per their conventions.

## Testing

- Chart CI: helm lint, kubeconform, chart-testing install in kind; e2e smoke with `indi_simulator_ccd`/`test_*` interface — full capture→process→DB→web pipeline, no hardware.
- Hardware validation on the camera node only after CI green. Known risk to watch: chronic per-exposure USB SuperSpeed resets seen on the operator's hardware (tracked in their host-provisioning repo) — verify containerized indiserver behaves no worse than bare metal; USB replug generally requires an edge-pod restart (document).

## Failure modes / operational notes

- Web/DB outage never stops capture writes to local processing, but DB outage blocks frame cataloging and task queues — single-node MariaDB is an accepted homelab risk. Upstream's built-in DB backup task is SQLite-only (`indi_allsky/video.py:1939`), so the chart ships an optional `mariadb-dump` CronJob writing to the data PVC.
- NFS outage stalls image writes → capture supervisor restarts workers; recovers when the mount returns.
- Web→daemon commands take up to 13 s (upstream DB polling) — documented, not a bug.
- Timelapse night runs on the camera node until phase 2; `nice 19` + Guaranteed QoS bounds impact.
- Schema migrations (accepted risk, decision 2026-08-20 "guarded parity"): v1 keeps upstream's runtime `flask db revision --autogenerate` (relocated into the web migrate initContainer), guarded by a mandatory pre-migrate `mariadb-dump` to the data PVC and a `flask db check` no-op skip. CI-committed revisions + an upgrade-path e2e are a hard prerequisite for the first `UPSTREAM_VERSION` bump (tracked as a chart-repo issue filed at release).
- Credential rotation does not automatically roll pods in `existingSecret` mode — rotation runbook step is a web+edge restart, or add Reloader annotations via the `podAnnotations` values.

## Open items (tracked, each gets an issue at implementation start)

1. Infrastructure-as-code home for the NAS NFS export (an operator-infrastructure item — no manual NAS-console step).
2. Phase-2 video-worker patch + upstream PR.
3. NFD vendor-ID list for camera autodiscovery (seed: ZWO, QHY; community-extensible).
4. USB reset interplay with containerized indiserver (burn-in observation on the operator's hardware).
5. Post-burn-in: drop the camera-node taint, enable share-with-protection; revisit the operator's kubelet swap-setting drift note before any k3s unit change on that node.
6. syncapi "web-only" topology recipe for chart users without RWX storage.
