# Container contract

What the `daemon` and `web` images expect from whatever runs them. This is the
interface the Helm chart is written against; it is also what you need if you
run the images directly.

The images are overlays on upstream indi-allsky's own container images. They
replace the entrypoints — no fixed startup sleeps, no `sudo chown`, no
migrations during web startup — and add environment-driven auth settings that
upstream only exposes through a hand-edited `flask.json`.

Related: [node contract](node-contract.md) ·
[implementation plan, Task A3](planning/implementation-plan.md) ·
chart-repo issue #2.

> **Upstream `file.py:line` citations in this document — and in the comments
> throughout `images/` — are valid at the currently pinned `UPSTREAM_VERSION`
> and nowhere else.** Line numbers move with every upstream release. Any
> re-pin must re-verify them as part of the change, not after it.

## Published images

| Image | Contents | Entrypoint |
| --- | --- | --- |
| `ghcr.io/jaxzin/indi-allsky-indiserver` | INDI server and camera drivers | upstream's `start_indiserver.sh` |
| `ghcr.io/jaxzin/indi-allsky-daemon` | capture / processing daemon | `/home/allsky/entrypoint-daemon.sh` |
| `ghcr.io/jaxzin/indi-allsky-web` | gunicorn web UI **and** the migration tooling | `/home/allsky/entrypoint-web.sh`; run `/home/allsky/migrate.sh` as the initContainer command |

Each is tagged `main` and with the contents of `UPSTREAM_VERSION`, for
`linux/amd64` and `linux/arm64`. Tags are mutable; the chart's
`image.digests.daemon` and `image.digests.web` are the digest-pin slots, and
each chart release publishes the digests it was tested against.

Both images run as **uid/gid 10001** and contain no `sudo` — the package is
purged, not just its sudoers policy, so the setuid binary is gone too.

## Paths inside the containers

| Path | What it is | Provided by |
| --- | --- | --- |
| `/home/allsky/indi-allsky` | the upstream checkout; **every** `flask`, `config.py` and `usertool.py` call must run from here (upstream ships no `FLASK_APP`, so the app is discovered from `./app.py`) | image |
| `/home/allsky/venv` | the Python virtualenv; `python3` outside it is the system interpreter and cannot import `indi_allsky` | image |
| `/etc/indi-allsky/flask.json` | rendered at every container start, mode `0600` | entrypoint |
| `/etc/indi-allsky-overlay/config-overlay.json` | optional GitOps config overlay on a separate projected ConfigMap volume | chart ConfigMap |
| `/var/www/html` | shared PVC parent mount | chart PVC |
| `/var/www/html/allsky` | application subtree under the shared parent | chart + entrypoints |
| `/var/www/html/allsky/images` | captured images | created by `migrate.sh` / `entrypoint-daemon.sh` |
| `/var/www/html/allsky/.state/migrations` | Alembic migration tree | `flask db init` |
| `/var/www/html/.state/backups` | sibling backup directory outside the application/nginx docroot | `migrate.sh` + scheduled backup CronJob |
| `/var/www/html/.state/config-overlay.applied` | exact applied-overlay checksum sentinel | web migration initContainer |

Upstream keeps migrations in `/var/lib/indi-allsky`, which is a per-container
`VOLUME` in its compose stack and therefore not shared. On Kubernetes the
migration tree has to live on the shared PVC, or the web and daemon pods
disagree about the schema history. Revisions are generated at runtime
(upstream ships none), so losing `.state/migrations` loses the history.

## Requirements on the chart

1. **MUST mount a memory-backed emptyDir at `/etc/indi-allsky`** in every pod running
   either image. Both entrypoints render `flask.json` there. Upstream ships
   the directory `0750` owned by `allsky`, but any Kubernetes volume mounted
   at that path shadows it with a root-owned one. `medium: Memory` keeps the
   rendered database URI and application keys off node disk.
2. **MUST set `securityContext.fsGroup: 10001`** on every pod that mounts
   `/etc/indi-allsky` or the data PVC. Verified empirically: with a root-owned
   `0755` mount the render step dies with
   `/etc/indi-allsky/.flask.json.tmp: Permission denied`; with gid `10001` and
   the group-write bit it renders.
3. **MUST mount the shared PVC parent at `/var/www/html`**, keeping the
   `/var/www/html/allsky` application subtree persistent across the web and
   daemon pods while leaving backups in the sibling `/var/www/html/.state`.
   `flask db upgrade head` cannot find prior revisions without the app subtree.
4. **MUST run `migrate.sh` as the web pod's initContainer**, with **both**
   volumes mounted (`/etc/indi-allsky` and the data PVC) and the full database
   and seeding environment. It holds the database to itself: gunicorn and the
   capture daemon both start only after it exits 0. Running migrations from N
   gunicorn replicas instead would race them over one Alembic history.
5. **MUST keep the v1 web workload single-writer:** exactly one replica, a
   Deployment strategy of `Recreate`, and no public replica-count value. This
   prevents two chart-managed web pods from running the migration initContainer
   concurrently during a rollout. It does **not** coordinate the separate
   scheduled-backup CronJob with migration DDL; that CronJob's `Forbid` policy
   only prevents scheduled backup Jobs from overlapping one another. The
   topology is owned by [issue #16](https://github.com/jaxzin/indi-allsky-helm/issues/16),
   and [A9 (#8)](https://github.com/jaxzin/indi-allsky-helm/issues/8) owns the
   end-to-end rollout and overlap proof.
6. **MUST apply `storage.retentionPolicy` symmetrically** to chart-generated
   shared-data and internal-MariaDB PVCs. `Retain` is the default recovery-set
   posture and adds Helm's keep annotation to both standalone claims; `Delete`
   is an explicit pre-uninstall choice and omits it from both. The MariaDB
   StatefulSet mounts its separately rendered RWO claim and does not use the
   Kubernetes-version-dependent StatefulSet PVC-retention field. Existing
   shared claims are never annotated or modified, and the StorageClass/PV
   reclaim policy still governs backing storage after PVC deletion.

## Environment contract

> **Two settings types trip people up.**
> **JSON-array variables** (`INDIALLSKY_OIDC_ALLOWED_GROUPS`,
> `INDIALLSKY_OIDC_ADMIN_GROUPS`, `INDIALLSKY_ADMIN_NETWORKS`) are **JSON array
> strings** — `'["group1","group2"]'` — not comma-separated lists.
> **Boolean variables** must be **exactly** `true` or `false`. `True`, `yes`,
> `1` and `0` are all rejected.
>
> Both are hard failures with a message naming the variable, on purpose. jq's
> `--argjson` accepts any well-formed JSON, so a typo would otherwise fail
> *open*: `OIDC_ALLOWED_GROUPS=null` is falsy at
> `auth_views.py:238`, which disables the group allow-list entirely, and a bare
> string is truthy at `auth_views.py:291`, where `set("admins")` is a set of
> *characters* — so any group sharing a single letter would be granted admin.

Error messages never echo the offending value, only its byte count: these run
in pods, and pod logs are widely readable.

### Database — both images

| Variable | Default | Meaning |
| --- | --- | --- |
| `MARIADB_USER` | *required* | database account |
| `MARIADB_PASSWORD` | *required* | its password |
| `MARIADB_DATABASE` | *required* | schema name. **Constrained:** letters, digits, `_`, `-`, `$`. (`indi-allsky` is fine.) |
| `INDIALLSKY_MARIADB_HOST` | *required* | database host. **Constrained:** letters, digits, `.`, `:`, `-`, `_` — hostnames, IPv4, and bare IPv6 all pass. |
| `INDIALLSKY_MARIADB_PORT` | `3306` | database port. **Constrained:** digits only. |
| `INDIALLSKY_MARIADB_SSL` | `false` | boolean; `true` adds `ssl_ca` + `ssl_verify_identity` to the DSN |
| `INDIALLSKY_MARIADB_CHARSET` | `utf8mb4` | connection charset. **Constrained:** letters, digits, `_`. |
| `INDIALLSKY_MARIADB_COLLATION` | `utf8mb4_unicode_ci` | connection collation. **Constrained:** letters, digits, `_`. |

The host contract deliberately admits bare IPv6, but the current image does
not yet bracket it while constructing the SQLAlchemy URI. End-to-end bare-IPv6
support is tracked in [issue #20](https://github.com/jaxzin/indi-allsky-helm/issues/20);
use DNS or IPv4 until that image-layer fix lands.

**The five "Constrained" rows are hard failures, not warnings.** Each of those
values is interpolated into the database URI at a position SQLAlchemy does *not*
percent-decode, so they cannot be encoded on the way in without corrupting them
(`make_url` returns the database component verbatim, `%20` and all). They are
validated by character class instead, which preserves the property that matters:
nothing reaching the DSN can introduce a URI delimiter, an extra query parameter,
or a different host. Without it, `INDIALLSKY_MARIADB_CHARSET=utf8mb4&ssl_verify_identity=false`
would append a real query parameter and silently disable certificate hostname
verification on an SSL connection. A value outside its class aborts the render
with an error naming the variable — the pod does not start with a
half-understood connection string.

The bare `MARIADB_*` names are the official mariadb image's own environment
contract — the database container reads those exact names to provision the
account — so the application side uses them verbatim to name the same account.
The `INDIALLSKY_MARIADB_*` names are connection settings the mariadb image has
no equivalent for.

Credentials are percent-encoded into the DSN, so a generated password
containing `@ : / ? & # %` is safe. (Upstream interpolates them raw, where such
a password silently re-points or truncates the URI instead of failing.)

### Flask and local auth — both images

| Variable | Default | Meaning |
| --- | --- | --- |
| `INDIALLSKY_FLASK_SECRET_KEY` | *required, non-empty* | Flask session signing key |
| `INDIALLSKY_FLASK_PASSWORD_KEY` | *required, non-empty* | Fernet key encrypting credentials at rest. **Losing it makes stored passwords unrecoverable.** |
| `INDIALLSKY_FLASK_AUTH_ALL_VIEWS` | `false` | boolean; require login for every view, not just the privileged ones |
| `INDIALLSKY_LOCAL_AUTH_ENABLE` | `true` | boolean; enable username/password login. Also gates admin seeding in `migrate.sh`. |
| `INDIALLSKY_FLASK_SESSION_COOKIE_SECURE` | `true` | boolean; sets **both** `SESSION_COOKIE_SECURE` and `REMEMBER_COOKIE_SECURE`. Set `false` **only** for deliberately plain-HTTP access — with `true` the browser never returns the cookie over HTTP, so login is impossible. TLS deployments keep `true`. |
| `INDIALLSKY_ADMIN_NETWORKS` | `[]` | JSON array of CIDR strings that get implicit admin. See below. |
| `INDIALLSKY_IMAGE_FOLDER` | `/var/www/html/allsky/images` | where captured images are written |
| `INDIALLSKY_MIGRATION_FOLDER` | `/var/www/html/allsky/.state/migrations` | Alembic migration tree |

**`ADMIN_NETWORKS` defaults to empty here, deliberately diverging from
upstream**, whose template pre-populates the RFC1918 and CGNAT ranges.
Upstream trusts `X-Forwarded-For` unconditionally and additionally auto-trusts
the pod's own interface subnets via `psutil`. On a cluster that turns "came
from a private address" into "is an admin" for anything able to set a header.
Empty is a *mitigation, not an elimination* — it removes the blanket grant and
makes operators opt back in explicitly.

### OIDC — both images, all optional

| Variable | Default | Meaning |
| --- | --- | --- |
| `INDIALLSKY_OIDC_ENABLE` | `false` | boolean |
| `INDIALLSKY_OIDC_AUTO_LOGIN` | `false` | boolean; redirect straight to the IdP instead of showing the login form. Absent from upstream's template but honoured at `auth_views.py:76`, so it is rendered explicitly. |
| `INDIALLSKY_OIDC_PROVIDER_NAME` | `""` | display name on the login button |
| `INDIALLSKY_OIDC_CLIENT_ID` | `""` | |
| `INDIALLSKY_OIDC_CLIENT_SECRET` | `""` | |
| `INDIALLSKY_OIDC_DISCOVERY_ENDPOINT` | `""` | `.well-known/openid-configuration` URL |
| `INDIALLSKY_OIDC_USERNAME_CLAIM` | `preferred_username` | claim used as the username |
| `INDIALLSKY_OIDC_ALLOWED_GROUPS` | `[]` | JSON array string; empty means *no group filter* |
| `INDIALLSKY_OIDC_ADMIN_GROUPS` | `[]` | JSON array string; members are granted admin |

When OIDC is enabled, the client ID and discovery endpoint must come either
from the chart's plain `oidc.clientId` / `oidc.discoveryEndpoint` values or,
when `credentials.existingSecret` is selected, from that Secret's fixed
`INDIALLSKY_OIDC_CLIENT_ID` / `INDIALLSKY_OIDC_DISCOVERY_ENDPOINT` keys.
The Secret is loaded after the plain ConfigMap and therefore wins if both
sources define a key. Existing Secret contents are opaque to Helm, so the
chart cannot preflight their presence. `INDIALLSKY_OIDC_CLIENT_SECRET` is
optional for public or PKCE clients in both modes.

**Not every OIDC key is env-drivable in v1.** `OIDC_USERINFO_ENDPOINT`,
`OIDC_SCOPES`, `OIDC_PKCE`, `OIDC_LOGO_URL`, `OIDC_ALLOWED_USERS` and
`OIDC_ADMIN_USERS` keep the values from upstream's `flask.json_template`.
These live in `flask.json` (`app.config`), which the config overlay does
**not** reach — the overlay applies to indi-allsky's own configuration, a
different store. Changing them in v1 means a patch in `patches/`. Intentional
scope limit; the defaults are the usual ones.

### Seeding and configuration — `migrate.sh` only

| Variable | Default | Meaning |
| --- | --- | --- |
| `INDIALLSKY_WEB_USER` | unset | admin username to seed. **Unset disables seeding entirely.** Must contain no spaces. |
| `INDIALLSKY_WEB_PASS` | — | admin password; must be at least 8 characters |
| `INDIALLSKY_WEB_NAME` | `Admin` | display name |
| `INDIALLSKY_WEB_EMAIL` | `admin@example.com` | must match `^[^@]+@[^@]+\.[^@]+$` |
| `INDIALLSKY_CONFIG_OVERLAY` | `/etc/indi-allsky/config-overlay.json` in the image; `/etc/indi-allsky-overlay/config-overlay.json` in this chart | overlay path; skipped when the file is absent |
| `INDIALLSKY_CONFIG_OVERLAY_SHA256` | chart-generated | SHA-256 of the canonical compact overlay JSON payload |
| `INDIALLSKY_CONFIG_OVERLAY_APPLIED_SENTINEL` | `/var/www/html/.state/config-overlay.applied` in this chart | fixed sentinel carrying the exact checksum last applied successfully |

The chart resolves overlay delivery by projecting the ConfigMap as its own
volume at `/etc/indi-allsky-overlay`; it does not use `subPath`. Kubernetes can
therefore update the projected file, while a pod restart remains necessary to
run migration/bootstrap and apply that payload to the database.

Seeding happens only when the database holds at most one account — the
internal `system` user that bootstrap creates. It never overwrites a real one.
On a fresh database, an existing application Secret must therefore include
`INDIALLSKY_WEB_PASS` with at least eight characters whenever
`INDIALLSKY_WEB_USER` is configured. Helm cannot inspect that value; the
migration initContainer validates it only when seeding actually applies.

Those three constraints are `usertool.py`'s own. `migrate.sh` checks them
immediately before seeding — not earlier — because whether seeding applies at
all is unknowable until the database is up and the accounts counted. Validating
earlier would turn "2 accounts already exist; not seeding" into a fatal error
on any deployment whose bootstrap secret has since been rotated away, which
would silently make `INDIALLSKY_WEB_PASS` permanently required. The checks
exist because `usertool.py` responds to a bad value by *prompting*, and in an
initContainer with no tty that is a hang or a bare `EOFError` traceback rather
than a diagnosis.

**Accepted risk: `INDIALLSKY_WEB_PASS` transits argv during seeding.**
`usertool.py` takes the password as `-p <value>`, so for the lifetime of that
call it is visible in `/proc/<pid>/cmdline` inside the container. Upstream
offers no `--password-stdin` equivalent, so avoiding this would mean patching
upstream. The exposure is contained rather than eliminated: pods do not share a
PID namespace by default, so only processes in this container can read it; the
initContainer runs alone, before any application container starts; and it runs
once on a fresh database rather than on every start. Contrast the database
password, which is passed to `mariadb-dump` via `MYSQL_PWD` specifically to
keep it out of argv — that one had a no-cost alternative and this one does not.
If `shareProcessNamespace: true` is ever set on the web pod, revisit this.

### Migrations and backups — `migrate.sh` only

| Variable | Default | Meaning |
| --- | --- | --- |
| `INDIALLSKY_PRE_MIGRATE_DUMP` | `true` | boolean; **must be exactly `true` or `false`.** `false` is the only way to skip the pre-migration dump; anything else is a hard failure. A typo that silently skipped the backup and then mutated the schema would invert the safety property this script exists to provide. |
| `INDIALLSKY_PRE_MIGRATE_DUMP_KEEP` | `8` | how many dumps to retain; must be a whole number ≥ 1 |
| `INDIALLSKY_BACKUP_DIR` | `/var/www/html/allsky/.state/backups` in the image; `/var/www/html/.state/backups` in this chart | persistent dump destination |

The image default is inside the nginx docroot and is retained for standalone
compatibility. The chart always overrides it to the sibling directory outside
that docroot. A6 additionally denies dot paths and mounts only the images
subtree into nginx; relocation and serving-side denial are independent layers.

### Capture daemon — `entrypoint-daemon.sh` only

| Variable | Default | Meaning |
| --- | --- | --- |
| `INDIALLSKY_DARK_CAPTURE_ENABLE` | `false` | boolean; must be exactly `true` or `false`. `true` runs dark-frame capture instead of normal capture. |
| `INDIALLSKY_DARK_CAPTURE_DAYTIME` | `true` | boolean; must be exactly `true` or `false`. `true` passes `--daytime`, `false` passes `--no-daytime`. |
| `INDIALLSKY_DARK_CAPTURE_BITMAX` | `16` | max bits returned by the camera |
| `INDIALLSKY_DARK_CAPTURE_MODE` | `average` | one of `flush`, `average`, `tempaverage`, `sigmaclip`, `tempsigmaclip` |
| `CAPTURE_TMPDIR` | unset | scratch directory for the capture process; useful when the data volume is network-backed |

Both dark-capture booleans are validated strictly, like every other boolean in
these images — `True`, `TRUE`, `1` and `yes` are all rejected, with an error
naming the variable (values themselves are never echoed, only their length). They are
checked at entrypoint start, before the readiness gate, so a typo fails in about
a second rather than ten minutes later. Neither can corrupt data, but silently
reinterpreting `DAYTIME=True` as "capture `--no-daytime` darks" is a bad
contract regardless of the stakes.

### Operational

| Variable | Default | Meaning |
| --- | --- | --- |
| `FORWARDED_ALLOW_IPS` | *unset by the image* | Read by **gunicorn itself**, not by these scripts. gunicorn's own default (`127.0.0.1,::1`) is correct for the chart's topology, where the only thing in front of gunicorn is a sidecar in the same pod. Set it from the chart only for a different topology — and never to `*` unless nothing untrusted can reach the pod directly. |
| `INDIALLSKY_DOCKER` | set to `1` by both entrypoints | an output, not an input; upstream uses it to detect a container |
| `TZ` | `UTC` | runtime timezone supplied by the chart's plain env ConfigMap |

## Migration behaviour

The migration path is split across two scripts and runs entirely inside one
advisory-lock holder's lifetime.

`migrate.sh` is the initContainer's entry point and does only non-secret
preflight:

1. Render `flask.json`; fail immediately on any missing or malformed setting.
2. Create the image folder and the migration folder's parent on the data volume.
3. Cross-check that the rendered DSN and the maintenance environment name the
   same endpoint. If they ever disagreed, the lock would serialize a database
   nobody was migrating.
4. Wait for the database — up to 100 attempts at 3s (5 minutes), logging the
   last connection error every tenth attempt, then exit non-zero. The pod's
   restart policy retries beyond that.
5. `exec` into `db-maintenance-lock.sh -- migrate-critical.sh`.

The wait is deliberately *outside* the lock: a pod waiting five minutes for a
cold MariaDB must not be blocking the scheduled backup for those five minutes.

`migrate-critical.sh` then runs, holding the lock throughout:

1. Snapshot the projected config overlay exactly once and verify that snapshot
   against `INDIALLSKY_CONFIG_OVERLAY_SHA256`.
2. `flask db init` if `MIGRATION_FOLDER/env.py` is absent. The test is on the
   *file*, not the directory: a subPath mount or a half-finished earlier run
   leaves an existing-but-empty directory, and a directory test would skip
   init there and then die at upgrade. Validate the resulting tree.
3. Decide whether any schema work is pending, using two **non-mutating** probes:
   `flask db current` versus `flask db heads`, and `flask db check`. Both fail
   closed — an unexpected status or unparseable output means "assume pending".
4. If work is pending, publish a verified pre-migration dump (below) unless the
   explicit `INDIALLSKY_PRE_MIGRATE_DUMP=false` escape hatch is set.
5. `flask db upgrade head` — **then** `flask db check`. That order matters: on a
   database that is merely behind the committed revisions, `check` reports a
   difference that `upgrade`, not a new revision, is the answer to.
6. If `check` still reports a genuine model/schema difference, autogenerate a
   revision and upgrade again.
7. `config.py bootstrap`, then the config overlay from the snapshot, then the
   admin seed.
8. Publish the applied-overlay checksum sentinel as the final commit point.

### The safety property

**No schema mutation without a fresh, verified backup.** Nothing that can
change the schema — `flask db upgrade head` included — runs before a dump has
been published, unless the two non-mutating probes in step 3 prove there is
nothing to apply, or the operator set the strict escape hatch.

That is a change from earlier releases, which upgraded first and only dumped
before the autogenerate branch. An already-committed revision could therefore
mutate the schema before any recovery artifact existed.

Publication is atomic and cannot clobber:

- the dump is written under `umask 077` to a hidden, uniquely named temporary
  file **in the destination directory**, so publication is a same-filesystem
  operation;
- it must be non-empty and pass `gzip -t`, is chmodded `0600`, and is fsynced
  before publication;
- it becomes visible under its final `pre-migrate_*.sql.gz` name only as a
  **hard link** from that already-verified inode. `ln` fails if the name
  exists, so there is no check-then-act window and no way to replace an
  existing artifact. `mv`, `mv -n`, unlink-then-link, and redirection or copy
  straight to the final path are all forbidden for that reason;
- a final-name collision is a nonzero error that leaves the existing artifact's
  inode and bytes exactly as they were, and does not continue to schema
  mutation;
- the destination directory is fsynced after the link, and the temporary
  pathname is removed on every outcome, including failure and handled signals.

Every path that comes from the environment is checked before use: absolute,
canonical with no symlink component, owned by uid 10001, and not writable by
group or other. `INDIALLSKY_BACKUP_DIR` and `INDIALLSKY_MIGRATION_FOLDER`
remain honoured; the chart supplies `/var/www/html/.state/backups` and
`/var/www/html/allsky/.state/migrations`.

Retention is count-based, scoped to the `pre-migrate_` prefix only, and runs
only after a successful publication. It can never see the scheduled backup's
prefix, and it never counts or removes a temporary file. This is why the count
must be at least 1: a retention of 0 would prune the dump taken moments
earlier, inverting the property.

**These dumps are not your backup strategy.** They are triggered by pending
schema work and retain the newest `INDIALLSKY_PRE_MIGRATE_DUMP_KEEP` (default
8). The chart's scheduled backup CronJob is a separate mechanism with its own
trigger and its own retention; neither substitutes for the other.

Credential initialization, root recovery, dump encryption boundaries, and the
required restore set/order are documented in
[Chart configuration](configuration.md#credential-lifecycle-and-root-recovery)
and [Backup protection and restore](configuration.md#backup-protection-and-restore).

### Serializing migrations and scheduled backups

`mariadb-dump --single-transaction` gives a consistent view of ordinary InnoDB
DML. It is **not** coordination for concurrent `ALTER`, `CREATE` or `DROP`, so
one replica plus `strategy: Recreate` (which prevents two migrations) and
`concurrencyPolicy: Forbid` (which prevents two scheduled backups) still leave
a migration and a scheduled dump free to overlap.

`db-maintenance-lock.sh` closes that. Both writers run through it:

    db-maintenance-lock.sh -- <command> [args...]

It takes one deterministic, database-scoped MariaDB named lock —
`indi-allsky:db-maint:v1:<first 32 hex of sha256(database name)>` — and holds
it for the entire lifetime of the protected command. The name carries no
credentials, is namespaced so it cannot collide with an unrelated application's
lock on a shared server, and is scoped to the database so two releases pointing
at different schemas do not serialize against each other.

MariaDB releases a named lock when the connection that took it ends, so a
one-shot `mariadb -e "SELECT GET_LOCK(...)"` acquires and immediately drops it.
The supervisor therefore keeps **one client process alive** across the child,
speaking to it through a pair of FIFOs.

Fixed internal constants, deliberately not chart values: five-second `GET_LOCK`
slices inside a 300-second acquisition deadline, a progress line every 30
seconds, and a ten-second TERM grace before the protected process group is
killed. Timing out returns `EX_TEMPFAIL` (75); a connector, ownership or
release failure returns `EX_UNAVAILABLE` (69) and takes precedence over any
child status, because the safety control itself failed. A normal child status
propagates exactly, and a handled signal returns 128 + signal. Nothing is
logged that contains a credential, a DSN or a connection URI.

**Limits.** A MariaDB named lock is scoped to one server connection. The
endpoint must be a single stable writable primary: Galera, replica endpoints,
load-balanced or statement-routed connections, and connectors that
transparently reconnect are unsupported. The lock coordinates this chart's two
cooperating jobs; it is not a database-wide DDL firewall.

### v1 caveat

Upstream ships no Alembic revisions, so this generates them at runtime, on
your cluster, unreviewed. That is a deliberate v1 compromise. CI-committed
revisions and an upgrade-path end-to-end test are a **hard prerequisite for
the first `UPSTREAM_VERSION` bump** — tracked in issue #9 — and the pre-migrate
dump is what makes the interim safe.

## Config overlay

The overlay is a JSON document merged over indi-allsky's live configuration on
every `migrate.sh` run, using `jq -s '.[0] * .[1]'`:

- **Objects merge recursively** — setting `MQTTPUBLISH.HOST` leaves
  `MQTTPUBLISH.PORT` alone.
- **Arrays are replaced wholesale**, never merged element-wise.
- **Keys cannot be removed.** Deleting a key from the overlay leaves the last
  value it set in the database. GitOps drift: the overlay is authoritative for
  the keys it mentions and inert for the keys it stops mentioning; to undo a
  setting, set it back explicitly.

**Never put credentials in the overlay.** It is a ConfigMap, stored and
mounted in plaintext, whereas the configuration's credential fields are
Fernet-encrypted at rest in the database. Putting a secret in the overlay
downgrades it.

The overlay is now the **only** way to set the MQTT broker host or a
non-default INDI server. Upstream's entrypoints rewrote both when they were
`localhost`; those rewrites are gone. The base configuration's
`INDI_SERVER: localhost` is already correct for the chart, where the INDI
server runs as a sidecar in the capture pod.

### Exact overlay-application barrier

The chart serializes the merged overlay once as canonical compact JSON and
hashes exactly those bytes. That digest is exposed as
`INDIALLSKY_CONFIG_OVERLAY_SHA256`; formatting of the pretty ConfigMap view is
not part of the identity. Chart-managed `INDI_SERVER`, `INDI_PORT`, and
`IMAGE_FOLDER` win before hashing, so an attempted operator override of those
keys cannot produce a false rollout identity.

The ConfigMap therefore carries **two** renderings of the same document:
`config-overlay.canonical.json` holds the byte-exact compact bytes the checksum
covers and is the only file the migration path reads, and `config-overlay.json`
is a pretty sibling for an operator reading `kubectl get configmap -o yaml`.
`INDIALLSKY_CONFIG_OVERLAY` points at the canonical one. Hashing the pretty
rendering would compare a re-serialization against a digest of something else.

Kubernetes updates a projected ConfigMap file in place while the pod runs, so
reading the overlay twice — once to verify, once to merge — is a genuine
time-of-check/time-of-use race. The migration path reads the projection
**exactly once** into a private snapshot in the memory-backed config volume,
verifies that snapshot's SHA-256, and merges from the snapshot. A projection
edited after that read simply fails the comparison, because the expected
checksum comes from the pod's own environment and rolls with the Deployment.

The web pod writes the exact checksum plus a single trailing newline to the
fixed sentinel path atomically (temporary file, fsync, then rename) only after
migration, bootstrap, overlay load, and admin seeding all succeed. Rename, not
the hard link the dumps use: this file must replace its predecessor, whereas a
dump must never replace anything. No failure path touches it, so an unchanged
sentinel keeps the edge pod waiting — the fail-safe direction.

The edge pod owns a separate, bounded, diagnostic startup gate before it
invokes the daemon entrypoint (`wait-overlay.sh`, its first initContainer): read
the sentinel, remove at most its single trailing newline, and require exact
byte-for-byte equality with the expected checksum. Missing, stale, empty, or
malformed content is not success. Only after that version gate passes does the
daemon entrypoint run its existing bounded `config.py dumpfile` loop, which is
the distinct database/bootstrap gate. This prevents capture from starting
against an overlay version that the web migration path did not finish.

`wait-overlay.sh` uses fixed internal timing — 120 attempts at 5 seconds, with
a progress line at least once a minute — and distinguishes five states in its
diagnostics: `missing`, `empty`, `malformed` (including a sentinel with two
trailing newlines, since exactly one is stripped), `stale`, and `unreadable`.
On exhaustion it exits non-zero rather than looping forever: an initContainer
that never exits is invisible to every restart and alerting mechanism the
cluster has, while a failing one is a CrashLoopBackOff someone sees.

The checksum is deliberately scoped to the canonical overlay payload. It is
not a rollout epoch and does not order an image/schema-only upgrade whose
overlay bytes are unchanged; an old sentinel can already match in that case,
and `config.py dumpfile` can succeed against the old configuration row. The
general migration-order race and its upgrade e2e are tracked by
[issue #9](https://github.com/jaxzin/indi-allsky-helm/issues/9). A6/A7 must not
interpret the overlay sentinel as proof that an unchanged-overlay schema
migration completed.

## Readiness

`entrypoint-daemon.sh` waits for `config.py dumpfile` to succeed before
starting capture — up to 120 attempts at 5s (10 minutes), then exits non-zero
with the last probe's real error.

The probe is `dumpfile`, not `user_count`, because `user_count` only proves the
user *table* exists: it returns `0` **successfully** in the window between
`flask db upgrade head` and `config.py bootstrap`, and because `migrate.sh`
runs in the web pod that window is a genuine cross-pod race. `dumpfile`
additionally requires a committed configuration row, which is what `allsky.py`
actually needs. Its output is discarded because a configuration dump contains
decrypted third-party credentials.
