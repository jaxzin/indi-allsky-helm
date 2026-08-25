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

It may also contain `INDIALLSKY_OIDC_CLIENT_ID`,
`INDIALLSKY_OIDC_CLIENT_SECRET`, `INDIALLSKY_OIDC_DISCOVERY_ENDPOINT`, and
`INDIALLSKY_WEB_PASS` when those features are configured. Existing Secret
contents are opaque to Helm. Do not combine `credentials.existingSecret` with
any inline application secret value.

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

OIDC inline mode requires `oidc.clientId` and `oidc.discoveryEndpoint`. The
client secret is optional for public/PKCE clients. In existing-Secret mode Helm
cannot inspect whether those optional keys are present, so the Secret contract
above applies. `oidc.localAuth: false` requires OIDC to remain enabled, and
`oidc.autoLogin: true` also requires OIDC.

A local admin is seeded only when `adminUser.username` is non-empty and the
database has no real user yet. In inline mode its password must be at least
eight characters; in existing-Secret mode `INDIALLSKY_WEB_PASS` is opaque.

## Config overlay and rollout barrier

`appConfig` is a JSON-shaped map containing only GitOps-owned, non-secret
upstream settings. Chart-managed `INDI_SERVER`, `INDI_PORT`, and `IMAGE_FOLDER`
always win. Arrays replace wholesale; object fields merge recursively.

Credential-bearing paths are rejected at render time because this data is a
ConfigMap. Configure those fields through the upstream UI after install until
an explicit Secret-backed integration exists.

The overlay is projected separately at
`/etc/indi-allsky-overlay/config-overlay.json`; it is not a `subPath` inside the
memory-backed `/etc/indi-allsky` volume. The chart hashes the canonical compact
JSON payload and exposes that exact digest in the environment. The future web
migration initContainer writes it atomically to
`/var/www/html/.state/config-overlay.applied` only after successful migration,
bootstrap, overlay application, and seeding. The future edge workload waits for
exact content equality before starting capture.

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

Pre-migration dumps are controlled by:

```yaml
migrations:
  preMigrateDump: true
  preMigrateDumpKeep: 8
```

The count must be an integer of at least one. Scheduled backups are separate:

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

## Capture values exposed before the edge workload

```yaml
edge:
  captureTmpDir: ""
  darks:
    enabled: false
    daytime: true
    bitmax: 16
    mode: average
```

`captureTmpDir`, when set, must be absolute. Dark mode is one of `flush`,
`average`, `tempaverage`, `sigmaclip`, or `tempsigmaclip`; booleans and whole
numbers are type-checked at Helm render time.

## Render-time validation and naming

Every A5 manifest invokes one centralized validation helper, and CI verifies
that wiring before running the unit suite. Invalid or mixed secret modes,
authentication dead ends, malformed database fields, invalid lists/enums,
unsafe ConfigMap credentials, and non-integer retention fail the Helm render
with an actionable message.

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
