# Chart configuration

The chart is still under construction, but its database, authentication,
overlay, and backup values are stable enough for the later web and edge
workloads to consume. `values.yaml` remains the complete reference; this guide
explains the mode choices and the fail-fast rules around them.

## Application credentials

Choose exactly one application credential source.

For development-only inline values:

```yaml
credentials:
  flaskSecretKey: replace-me
  flaskPasswordKey: replace-me
  mariadbPassword: replace-me
```

For a pre-provisioned Secret:

```yaml
credentials:
  existingSecret: indi-allsky-app
```

The existing Secret must contain these fixed keys:

- `INDIALLSKY_FLASK_SECRET_KEY`
- `INDIALLSKY_FLASK_PASSWORD_KEY`
- `MARIADB_PASSWORD`

When OIDC is enabled, its client ID and discovery endpoint must come either
from the plain `oidc.clientId` / `oidc.discoveryEndpoint` values or from this
Secret's fixed `INDIALLSKY_OIDC_CLIENT_ID` /
`INDIALLSKY_OIDC_DISCOVERY_ENDPOINT` keys. The optional
`INDIALLSKY_OIDC_CLIENT_SECRET` key is not required for public or PKCE clients.
The Secret is loaded after the plain ConfigMap and wins if both sources define
the same variable.
When `adminUser.username` is configured against a fresh database, the Secret
must also contain `INDIALLSKY_WEB_PASS` with at least eight characters so the
migration initContainer can seed that user. Existing Secret contents are
opaque to Helm, so the chart cannot preflight these conditional keys. The
migration initContainer validates `INDIALLSKY_WEB_PASS` only when seeding
actually applies; OIDC depends on receiving its client ID and discovery
endpoint at runtime. Do not combine `credentials.existingSecret` with any
inline application secret value.

## Internal or external database

Internal MariaDB is the default. Its recoverable root credential is deliberately
separate from the application credential and is mounted only into MariaDB:

```yaml
mariadb:
  enabled: true
  rootCredentials:
    existingSecret: indi-allsky-mariadb-root
```

That Secret has one fixed key, `MARIADB_ROOT_PASSWORD`. An inline
`mariadb.rootCredentials.password` exists for development only. The chart
rejects mixed root modes, any resolved root/application Secret name collision,
and a missing root source. The scheduled backup receives only the application
database password; it never receives the root Secret.

Internal MariaDB is a one-replica StatefulSet behind a headless Service. It
runs as uid/gid/fsGroup 999, reads both passwords from mounted files, and uses
startup, readiness, and liveness probes. The root account is restricted with
`MARIADB_ROOT_HOST=localhost`.

For an external database:

```yaml
mariadb:
  enabled: false
externalDatabase:
  host: db.example.com
  port: 3306
  database: indi_allsky
  username: indi_allsky
  ssl: false
  charset: utf8mb4
  collation: utf8mb4_unicode_ci
```

Root settings and the chart's scheduled backup must be disabled in external
mode. Set `externalDatabase.ssl: true` only when the external endpoint presents
a certificate valid for its configured host. Charset and collation accept only
letters, digits, and underscore so they cannot add database-URI query fields.
Custom or private certificate authorities are not configurable in v1; the
external server must chain to the CA bundle already present in the application
image.
Bare IPv6 hosts remain valid chart input, but the current image needs the
[URI-bracketing fix tracked in #20](https://github.com/jaxzin/indi-allsky-helm/issues/20)
before that connection mode works end to end. Use a DNS name or IPv4 address
until it closes.

### Web migration single-writer topology

The v1 web Deployment is deliberately fixed at one replica with strategy
`Recreate`; there is no public web replica-count value. This ensures only one
chart-managed migration initContainer can write the shared Alembic history
during a rollout. [Issue #16](https://github.com/jaxzin/indi-allsky-helm/issues/16)
owns this single-writer contract, and
[A9 (#8)](https://github.com/jaxzin/indi-allsky-helm/issues/8) owns its
end-to-end rollout and overlap proof.

There are three serialization layers, and they cover different overlaps:

| Layer | Prevents |
| --- | --- |
| One replica + `strategy: Recreate` | two chart-managed migrations |
| CronJob `concurrencyPolicy: Forbid` | two scheduled backup Jobs |
| Shared MariaDB advisory lock | a migration and a scheduled backup overlapping, in either start order |

The first two cannot see each other, which is why the third exists: a scheduled
`mariadb-dump` can otherwise run straight through a migration's `ALTER`.
`--single-transaction` gives a consistent view of ordinary DML and is not
coordination for DDL. Both writers now run through
`db-maintenance-lock.sh`, which holds one database-scoped named lock in a live
session for the whole critical section — see
[the container contract](container-contract.md#serializing-migrations-and-scheduled-backups)
for the lock identity, the bounded timing, and the stable-primary requirement.

**Scaling implication.** The one-replica limit is a v1 property of the
migration and seeding path, not a performance ceiling anyone chose. The lock is
a second layer under it, not a licence to raise the replica count.

### Credential lifecycle and root recovery

The official MariaDB initialization variables and their `_FILE` equivalents
apply only while `/var/lib/mysql` is empty. Application and root credentials
therefore become database state on first initialization. Changing either
Kubernetes Secret later does **not** rotate an existing MariaDB account and can
instead make the application or maintenance login fail. Rotation must be one
coordinated, automated change: update the database-side account first, update
the corresponding Secret, then roll the affected workloads. A Secret-only
rollout is not a credential-rotation procedure.

Preserve the separate root Secret as recovery material. An application-schema
dump does not include MariaDB root credentials, system tables, or grants. If the
root credential is lost while a populated database PVC remains, setting a new
Secret value will not reset it; recovery requires a deliberate MariaDB recovery
procedure in a maintenance window, followed by a coordinated Secret and
workload update. The chart does not render an automatic root-recovery Job.

The internal database, its datadir PVC, and the shared application PVC belong
to exactly one Helm release. Do not share or rebind either PVC across releases.
External deployments should likewise use a distinct schema and application
account for each release.

## Authentication

Secure session cookies are enabled by default:

```yaml
web:
  sessionCookieSecure: true
  authAllViews: false
  adminNetworks: []
```

Set `sessionCookieSecure: false` only for deliberate plain-HTTP access.
`adminNetworks` is a list of CIDR strings; the empty default removes upstream's
blanket RFC1918 list but cannot remove upstream's automatic trust of local
interface networks.

OIDC inline mode requires `oidc.clientId` and `oidc.discoveryEndpoint`. In
existing-Secret mode those fields may remain empty only when the corresponding
fixed keys are present in the Secret, whose contents Helm cannot inspect. The
client secret is optional for public/PKCE clients in both modes.
`oidc.localAuth: false` requires OIDC to remain enabled, and
`oidc.autoLogin: true` also requires OIDC.

A local admin is seeded only when `adminUser.username` is non-empty and the
database has no real user yet. In inline mode its password must be at least
eight characters; in existing-Secret mode `INDIALLSKY_WEB_PASS` must meet the
same runtime requirement on a fresh database, although its value is opaque to
Helm.

## Config overlay and rollout barrier

`appConfig` is a JSON-shaped map containing only GitOps-owned, non-secret
upstream settings. Chart-managed `INDI_SERVER`, `INDI_PORT`, and `IMAGE_FOLDER`
always win. Arrays replace wholesale; object fields merge recursively.

Credential-bearing paths are rejected at render time because this data is a
ConfigMap. Configure those fields through the upstream UI after install until
an explicit Secret-backed integration exists.

The overlay is projected on its own volume at `/etc/indi-allsky-overlay`; it is
not a `subPath` inside the memory-backed `/etc/indi-allsky` volume, because a
`subPath` mount resolves once at container start and never receives a ConfigMap
update. The ConfigMap holds two renderings: `config-overlay.canonical.json`,
the byte-exact compact payload the checksum covers and the only file the
migration path reads, and `config-overlay.json`, a pretty sibling for humans.

The web pod's migration initContainer reads the projection exactly once into a
private snapshot, verifies that snapshot against the expected digest, merges
from the snapshot, and — only after successful migration, bootstrap, overlay
application and seeding — writes the checksum atomically to
`/var/www/html/.state/config-overlay.applied`. The edge pod's
`wait-for-overlay` initContainer requires exact byte equality with that
sentinel before capture starts, and reports `missing`, `empty`, `malformed` and
`stale` as distinct diagnostics.

This sentinel is an **overlay-version barrier**, not a general schema-migration
barrier. An image/schema-only upgrade can leave the canonical overlay checksum
unchanged, allowing the old sentinel to match before the new migration finishes.
[Issue #9](https://github.com/jaxzin/indi-allsky-helm/issues/9) owns the required
upgrade-path ordering decision and e2e coverage; do not treat a matching overlay
sentinel as proof that an unchanged-overlay schema upgrade has completed.

## Shared storage and backups

The shared PVC is mounted at `/var/www/html`. Application data lives under
`/var/www/html/allsky`; database backups live in the sibling
`/var/www/html/.state/backups`, outside the nginx docroot.

### Storage lifecycle

`storage.retentionPolicy` is either `Retain` (the safe default) or `Delete`.
It applies symmetrically to every chart-generated part of the persistent
recovery set:

- `Retain` adds `helm.sh/resource-policy: keep` to both the generated shared
  PVC and the standalone internal-MariaDB PVC.
- `Delete` omits the keep annotation from both PVCs, so Helm deletes both on
  uninstall.

The MariaDB claim is a standalone Helm-managed PVC mounted into the StatefulSet;
the chart deliberately does not rely on the StatefulSet PVC-retention field,
which is not compatible with the chart's Kubernetes 1.26 floor. Scaling the
single-replica database does not create or delete claims.

The database, image archive, migration history, and sibling backups are useful
as one coherent recovery set. Retaining only one generated PVC can leave an
operator with images but no matching database, or a database without its
migration history and image files, so one value governs both. A shared PVC
selected through `storage.data.existingClaim` is never created, annotated, or
otherwise modified by this chart. External-database mode creates no MariaDB
PVC; the policy still applies to a chart-generated shared PVC.

To intentionally remove generated storage during an automated uninstall,
first run a CI-driven Helm upgrade setting `storage.retentionPolicy: Delete`.
Wait for the release to apply, verify that neither generated PVC carries the
Helm keep annotation, and only then let CI uninstall the release. Uninstalling
while the value is `Retain` deliberately leaves both generated PVCs behind.

For a retained reinstall, inventory and back up the PVCs first. Reuse the same
release name, namespace, and storage settings so the generated shared-PVC and
MariaDB-PVC names remain stable. A retained shared claim may instead be
referenced through `storage.data.existingClaim`; the internal MariaDB claim has
no arbitrary existing-claim value, so a differently named release must restore
or migrate that database rather than silently adopting it. Any Helm ownership
reconciliation must be codified and applied through CI, never performed as an
ad-hoc metadata edit.

`Delete` controls PVC deletion, not the final fate of the backing volume. After
a PVC is deleted, the StorageClass/PersistentVolume reclaim policy remains
authoritative: a `Retain` PV still requires the storage operator's normal
recovery or cleanup workflow, while a `Delete` PV may remove the underlying
storage.

Both `storage.data.size` and `mariadb.persistence.size` must be non-empty
strings; Kubernetes validates whether their text is a storage quantity. Both
`storageClassName` values must be strings; an empty string selects the cluster
default, while a non-empty value must be a valid DNS subdomain. The chart quotes
all four scalar sinks in PVC manifests so a multiline value cannot add YAML
documents or sibling fields.

Pre-migration dumps are controlled by:

```yaml
migrations:
  preMigrateDump: true
  preMigrateDumpKeep: 8
```

The count must be an integer of at least one. The current pre-migration path
writes directly to the timestamped final filename. A failed pipeline can leave
a partial final-looking file, and two runs in the same second can collide. The
script still aborts before schema mutation. Its `gzip -t` and non-empty checks
are necessary integrity guards on a successful run, but they cannot prove that
an artifact left by a failed, ambiguous, or overlapping run contains one
complete SQL dump. Such an artifact is invalid and must not be salvaged, even
if those checks pass.
Before relying on recovery material, obtain an unambiguous pre-migration run
that reaches its success message without overlap, or use an already-atomic
scheduled backup. Permanent atomic publication and collision prevention for
the pre-migration path are tracked in
[issue #22](https://github.com/jaxzin/indi-allsky-helm/issues/22).

Scheduled backups are separate and already use a unique temporary file,
gzip/non-empty verification, and an atomic rename:

```yaml
mariadb:
  backup:
    enabled: true
    schedule: "20 4 * * *"
    retentionDays: 14
```

The schedule uses the Kubernetes controller's timezone. The chart targets
Kubernetes 1.26 and intentionally does not render `CronJob.spec.timeZone`.
The CronJob uses `Forbid`, a bounded execution budget, verified gzip output,
an atomic unique final name, modes `0700`/`0600`, and retention scoped only to
`indi-allsky_scheduled_*.sql.gz`. It never sweeps `pre-migrate_*` dumps.

### Backup protection and restore

Both scheduled and pre-migration `.sql.gz` files are compressed, **not
encrypted**. Encryption at rest, backup transport security, repository access,
and off-cluster retention belong to the storage class and the operator's backup
automation.

A usable recovery set contains more than the SQL dump:

- a gzip-verified logical dump;
- the exact application Secret, especially the Flask signing key and Fernet
  password key needed to read encrypted configuration fields;
- the persistent Alembic migration history under the application `.state`
  directory;
- the image archive on the shared PVC; and
- separately provisioned database users, passwords, and grants, including the
  preserved root recovery credential where applicable.

Restore into a compatible MariaDB version and a prepared target schema/account
with the required grants. Quiesce writers, verify the gzip stream and dump,
restore it, restore the matching migration history and image data, then restart
the workloads with the matching application Secret. The chart does not yet
render a restore Job. The automated restore proof is owned by the
[A9 handoff](https://github.com/jaxzin/indi-allsky-helm/issues/8#issuecomment-5417845854),
and the final operator procedure by the
[A10 handoff](https://github.com/jaxzin/indi-allsky-helm/issues/10#issuecomment-5417846008);
both must land before the first supported release or upgrade.

## Serving path and the proxy boundary

The web pod runs `migrate` then `static-copy` as initContainers, and `gunicorn`
then `nginx` as its containers.

**Gunicorn binds `127.0.0.1:8000` and nothing else.** That bind, not a network
policy, is the boundary that makes gunicorn's own `FORWARDED_ALLOW_IPS` default
(`127.0.0.1,::1`) trustworthy — anything that could reach `:8000` directly could
also set `X-Forwarded-For` and be treated as an admin. Standard NetworkPolicy
selects pods, not containers, so it cannot express "same pod only"; there is no
selector that would do this job, which is why the bind does it. Gunicorn
advertises no `containerPort` and its probes are `exec`, because a kubelet probe
connects to the pod IP that loopback-bound gunicorn never answers.

nginx listens on `:8080` and is the only Service target. It serves exactly two
things: the images subtree of the data volume, mounted read-only through a
`subPath` so the container cannot reach the `.state` sibling holding database
dumps and the Alembic tree, and the static assets `static-copy` copied out of
the web image. Everything else is a 404, dot paths included — 404 rather than
403, because a 403 confirms the path exists. `/healthz` is nginx's own liveness
and readiness endpoint and deliberately does not touch gunicorn.

`X-Forwarded-Proto` is honoured when an upstream proxy sets `http` or `https`
and otherwise falls back to this hop's own scheme, so the application builds
`https://` URLs behind a TLS-terminating Ingress and correct URLs without one.

The sidecar also sets `absolute_redirect off`. nginx defaults that directive
**on**, which rewrites every redirect it generates — the site-root 302 and the
implicit trailing-slash 301 on image subdirectories — into an absolute URL
built from the request's Host header and the port nginx is listening on. Behind
a TLS-terminating Ingress that sends browsers to `http://host:8080/...`: wrong
scheme, unpublished port. Turning it off keeps those redirects relative, so
they resolve against whatever the client actually connected to. Upstream
responses are unaffected — `proxy_redirect off` passes gunicorn's own Location
headers through untouched.

This is worth knowing when reproducing a redirect problem: through
`kubectl port-forward` the client really is talking to `host:8080`, so an
absolute redirect looks correct there and only misbehaves through the Ingress.

`web.ingress` is off by default and renders a single host with the configured
class name, annotations and optional TLS when enabled.

## Network policy

`networkPolicy.enabled` defaults to `true` and renders **ingress-only**
policies:

- the web pod admits `:8080` and nothing else — notably not gunicorn's `:8000`;
- the edge pod admits no ingress at all;
- the internal database admits `:3306` only from this release's `web`, `edge`
  and `mariadb-backup` components, selected by label in the same namespace —
  never a namespace-wide allow.

**No egress policy is rendered anywhere, deliberately.** The chart supports an
external database, an OIDC provider, an MQTT broker, upload targets and an
external INDI server; standard NetworkPolicy cannot express those destinations
portably, and a partial egress policy would break them while looking like
protection. Set `networkPolicy.enabled: false` if your CNI does not enforce
NetworkPolicy and you would rather not carry objects that do nothing.

The database policy renders only when `mariadb.enabled` is `true`. With an
external database there is no pod here to select.

## Edge scheduling, devices and priority

```yaml
edge:
  priorityClass:
    mode: create            # create | reference | disabled
    name: ""
    value: 1000000
    preemptionPolicy: PreemptLowerPriority
  supplementalGroups: []
  captureTmpDir: ""
  sensors:
    enabled: false
  devices:
    mode: none              # none | device-plugin | hostpath
```

**Secure defaults.** `devices.mode: none` runs the INDI simulator: the edge pod
schedules anywhere, mounts no host path, and runs no privileged container.
Sensors are off, and there are no supplemental groups. Nothing in the default
values requires a camera node or host devices.

| Mode | Scheduling | Privilege |
| --- | --- | --- |
| `none` | anywhere | none |
| `device-plugin` (preferred for hardware) | extended resource, no node label | none |
| `hostpath` (explicit opt-in) | camera and/or sensor node label | `indiserver` privileged for a local camera |

Host device entries are objects, never bare strings, and the chart renders the
`type` and `readOnly` you state rather than inferring access from a path:

```yaml
edge:
  devices:
    mode: hostpath
    camera:
      hostPaths:
        - path: /dev/bus/usb
          type: Directory      # Directory | CharDevice
          readOnly: false
    sensors:
      hostPaths:
        - path: /dev/i2c-1
          type: CharDevice
          readOnly: false
        - path: /sys/bus/w1    # the one-wire tree is only read
          type: Directory
          readOnly: true
```

Device-plugin resources merge into the correct container's requests *and*
limits without replacing the base cpu/memory: the camera resource goes to
`indiserver`, the sensor resource to `daemon`.

`supplementalGroups` is rejected outside `hostpath` mode, because group ids only
grant access to host device nodes. Sensor placement is independent of the
camera: enabling hostPath sensors adds the sensors label whether or not a camera
is attached locally.

**PriorityClass ownership is a tri-state, because a PriorityClass is
cluster-scoped while a release is not.** `create` (the default) makes this
release own one class whose generated name carries the namespace, the release
identity, and the spec it intends, so two releases cannot silently target the
same object. `reference` points at a class an external owner — IaC/CI, or one
designated release — created, and renders no object. `disabled` renders neither
the object nor `priorityClassName`. `name` is required in `reference` mode and
rejected in the other two. Values above Kubernetes'
`HighestUserDefinablePriority` (1000000000) are rejected at render time.

`indiserver.mode: external` removes the sidecar and every local camera mount,
resource and privilege, and removes the camera node requirement. Independently
enabled sensors keep working.

**Probe limits.** The sidecar's startup, readiness and liveness probes are TCP
checks on 7624, because indiserver speaks the INDI protocol rather than HTTP.
They prove the process is listening, not that the camera is healthy: a driver
that has stopped responding still holds the listener open. Capture health is
the daemon's opt-in `edge.freshnessProbe`, which is fail-closed — a missing
latest image counts as stale — so do not enable it before the first frame
exists, and set `maxAgeSeconds` comfortably above your longest capture cadence.
The daemon has no default liveness probe for that reason. None of these
timings are public values.

`captureTmpDir`, when set, must be absolute. Empty keeps the image default;
`/tmp` reuses the daemon container's existing scratch emptyDir; any other path
gets a dedicated emptyDir and is rejected if it would overlap the rendered
config, the projected overlay, or the data volume. Dark mode is one of `flush`,
`average`, `tempaverage`, `sigmaclip`, or `tempsigmaclip`; booleans and whole
numbers are type-checked at Helm render time.

## Secret projection

The application Secret is **never** consumed through a blanket `envFrom`. Each
container declares an explicit `secretKeyRef` allowlist:

| Container | Receives |
| --- | --- |
| `migrate` | database and Flask keys, plus the OIDC and admin-seed keys when those features are enabled |
| `gunicorn` | database and Flask keys, plus OIDC keys — never the admin bootstrap password |
| `daemon` | database and Flask keys only |
| `static-copy`, `nginx`, `wait-for-overlay`, `indiserver` | nothing |

Chart-owned non-secret settings arrive through the env ConfigMap's `envFrom`, so
an opaque Secret cannot override them. Optional keys are projected with
`optional: true`, which keeps the documented "OIDC client id and discovery
endpoint may live in either place" behaviour working with
`credentials.existingSecret`.

The separate MariaDB root Secret reaches the database container and nothing
else. CI proves that over the whole rendered release, not just per workload.

## Render-time validation and naming

Every manifest invokes one centralized validation helper, and CI verifies that
wiring before running the unit suite — including that the wiring list and
`templates/` have not diverged, so a new template cannot skip validation by
being unknown to the check. Invalid or mixed secret modes, authentication dead
ends, malformed database fields, invalid lists/enums, unsafe ConfigMap
credentials, non-integer retention, incoherent PriorityClass ownership,
malformed host device entries, a device mode that would silently ignore the
settings given to it, and a capture scratch path that would shadow a mount all
fail the Helm render with an actionable message.

Generated names preserve semantic suffixes and stay within Kubernetes limits.
Normalization or truncation adds an eight-character hash derived from the
original name, so releases such as `foo.bar` and `foo-bar` cannot collide.
Helm-valid release names beginning with a digit remain supported: generated
Service names receive an alphabetic `svc-` prefix and the original-input hash
required for collision resistance, while Secret and PVC names are unchanged.
CronJob names use a 52-character ceiling to leave room for controller-generated
Job suffixes.

`image.pullSecrets` follows the standard Kubernetes shape:

```yaml
image:
  pullSecrets:
    - name: registry-auth
```

Each entry must contain only a non-empty, DNS-subdomain-valid `name`.
