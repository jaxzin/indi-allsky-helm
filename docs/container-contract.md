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
| `/etc/indi-allsky/config-overlay.json` | optional GitOps config overlay | chart ConfigMap |
| `/var/www/html/allsky` | the shared data volume | chart PVC |
| `/var/www/html/allsky/images` | captured images | created by `migrate.sh` / `entrypoint-daemon.sh` |
| `/var/www/html/allsky/.state/migrations` | Alembic migration tree | `flask db init` |
| `/var/www/html/allsky/.state/backups` | pre-migration database dumps | `migrate.sh` |

Upstream keeps migrations in `/var/lib/indi-allsky`, which is a per-container
`VOLUME` in its compose stack and therefore not shared. On Kubernetes the
migration tree has to live on the shared PVC, or the web and daemon pods
disagree about the schema history. Revisions are generated at runtime
(upstream ships none), so losing `.state/migrations` loses the history.

## Requirements on the chart

1. **MUST mount an emptyDir at `/etc/indi-allsky`** in every pod running
   either image. Both entrypoints render `flask.json` there. Upstream ships
   the directory `0750` owned by `allsky`, but any Kubernetes volume mounted
   at that path shadows it with a root-owned one.
   *(Whether that emptyDir is `medium: Memory` is a chart-side choice: memory
   keeps the rendered secrets off the node's disk, at the cost of counting
   against the pod's memory limit. The image works either way.)*
2. **MUST set `securityContext.fsGroup: 10001`** on every pod that mounts
   `/etc/indi-allsky` or the data PVC. Verified empirically: with a root-owned
   `0755` mount the render step dies with
   `/etc/indi-allsky/.flask.json.tmp: Permission denied`; with gid `10001` and
   the group-write bit it renders.
3. **MUST keep `/var/www/html/allsky` persistent and shared** across restarts
   and across the web and daemon pods. `flask db upgrade head` cannot find
   prior revisions without it.
4. **MUST run `migrate.sh` as the web pod's initContainer**, with **both**
   volumes mounted (`/etc/indi-allsky` and the data PVC) and the full database
   and seeding environment. It holds the database to itself: gunicorn and the
   capture daemon both start only after it exits 0. Running migrations from N
   gunicorn replicas instead would race them over one Alembic history.

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
| `MARIADB_DATABASE` | *required* | schema name |
| `INDIALLSKY_MARIADB_HOST` | *required* | database host |
| `INDIALLSKY_MARIADB_PORT` | `3306` | database port |
| `INDIALLSKY_MARIADB_SSL` | `false` | boolean; `true` adds `ssl_ca` + `ssl_verify_identity` to the DSN |
| `INDIALLSKY_MARIADB_CHARSET` | `utf8mb4` | connection charset |
| `INDIALLSKY_MARIADB_COLLATION` | `utf8mb4_unicode_ci` | connection collation |

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
| `INDIALLSKY_CONFIG_OVERLAY` | `/etc/indi-allsky/config-overlay.json` | overlay path; skipped when the file is absent |

Seeding happens only when the database holds at most one account — the
internal `system` user that bootstrap creates. It never overwrites a real one.

Those three constraints are `usertool.py`'s own. `migrate.sh` checks them up
front because `usertool.py` responds to a bad value by *prompting*, and in an
initContainer with no tty that is a hang or a bare `EOFError` traceback rather
than a diagnosis.

### Migrations and backups — `migrate.sh` only

| Variable | Default | Meaning |
| --- | --- | --- |
| `INDIALLSKY_PRE_MIGRATE_DUMP` | `true` | boolean-ish; anything other than `true` skips the pre-migration dump |
| `INDIALLSKY_PRE_MIGRATE_DUMP_KEEP` | `8` | how many dumps to retain; must be a whole number ≥ 1 |
| `INDIALLSKY_BACKUP_DIR` | `/var/www/html/allsky/.state/backups` | where dumps are written; lets the chart keep database dumps off the nginx docroot |

### Capture daemon — `entrypoint-daemon.sh` only

| Variable | Default | Meaning |
| --- | --- | --- |
| `INDIALLSKY_DARK_CAPTURE_ENABLE` | `false` | `true` runs dark-frame capture instead of normal capture |
| `INDIALLSKY_DARK_CAPTURE_DAYTIME` | `true` | `true` passes `--daytime`; **any other value passes `--no-daytime`** |
| `INDIALLSKY_DARK_CAPTURE_BITMAX` | `16` | max bits returned by the camera |
| `INDIALLSKY_DARK_CAPTURE_MODE` | `average` | one of `flush`, `average`, `tempaverage`, `sigmaclip`, `tempsigmaclip` |
| `CAPTURE_TMPDIR` | unset | scratch directory for the capture process; useful when the data volume is network-backed |

The two dark-capture booleans follow upstream's `== "true"` convention rather
than the strict validation used for `flask.json` settings: a value that is not
exactly `true` means false. They select a capture mode, not an authorisation
decision, so a typo produces the safe default rather than a fail-open.

### Operational

| Variable | Default | Meaning |
| --- | --- | --- |
| `FORWARDED_ALLOW_IPS` | *unset by the image* | Read by **gunicorn itself**, not by these scripts. gunicorn's own default (`127.0.0.1,::1`) is correct for the chart's topology, where the only thing in front of gunicorn is a sidecar in the same pod. Set it from the chart only for a different topology — and never to `*` unless nothing untrusted can reach the pod directly. |
| `INDIALLSKY_DOCKER` | set to `1` by both entrypoints | an output, not an input; upstream uses it to detect a container |
| `TZ` | baked to `UTC` at build time | change it by rebuilding, not at runtime |

## Migration behaviour

`migrate.sh`, in order:

1. Render `flask.json`; fail immediately on any missing or malformed setting.
2. Create the image folder and the `.state` directory on the data volume.
3. Wait for the database — up to 100 attempts at 3s (5 minutes), logging the
   last connection error every tenth attempt, then exit non-zero. The pod's
   restart policy retries beyond that.
4. `flask db init` if `MIGRATION_FOLDER/env.py` is absent. The test is on the
   *file*, not the directory: a subPath mount or a half-finished earlier run
   leaves an existing-but-empty directory, and a directory test would skip
   init there and then die at upgrade.
5. `flask db upgrade head` — **then** `flask db check`. That order matters: on
   a database that is merely behind the committed revisions, `check` reports a
   difference that `upgrade`, not a new revision, is the answer to.
6. If `check` reports a genuine model/schema difference: take a dump, verify
   it, prune old ones, autogenerate a revision, upgrade again.
7. `config.py bootstrap`, then the config overlay, then the admin seed.

### The safety property

**No schema mutation without a fresh, verified backup.** Before any
autogenerated migration runs, `migrate.sh` takes a `mariadb-dump`, checks it
is a complete gzip stream *and* non-empty, and only then generates and applies
the revision. If the dump fails at any point the script exits and the schema
is untouched.

This is why the retention count must be at least 1: a retention of 0 would
prune the dump taken moments earlier, inverting the property. To skip the dump
deliberately, set `INDIALLSKY_PRE_MIGRATE_DUMP=false` — appropriate only for
an external database whose backups a DBA already manages.

**These dumps are not your backup strategy.** They are triggered by a schema
change and retain the newest `INDIALLSKY_PRE_MIGRATE_DUMP_KEEP` (default 8).
The chart's scheduled mariadb backup CronJob is a separate mechanism with its
own trigger and its own retention; neither substitutes for the other.

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
