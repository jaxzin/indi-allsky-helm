# indi-allsky-helm Chart Repo Implementation Plan (Plan A)

> **Provenance:** migrated 2026-08-25 from the author's private planning workspace, with operator-specific details (private hostnames, internal repo and service names) genericized. The live execution record is this repository's issue tracker (issues #1–#10); this is a historical design record, not living documentation.

## Execution status (2026-08-25)

- **A1 ✅** — repo `jaxzin/indi-allsky-helm` created as code by tofu/github's first apply ("2 to add" / "2 added"; main ruleset active). Delivery chain: jaxzin-infra-bootstrap PRs #34 + #42–#52 (push-mirror-as-code, fork-2 reconcile, secrets bootstrap scripts).
- **A2 ✅** — chart-repo PRs #11 + #13. Images `ghcr.io/jaxzin/indi-allsky-indiserver:{main,indi_v2026.08.01}` published multi-arch (amd64+arm64), public.
- **A4 ✅** — chart-repo PR #12. Values contract landed byte-faithful to this plan's block (one necessary fix: PriorityClass `value` needs `| int` — helm renders 1e+06 otherwise).
- **A3 ⏳** — Batch 2 in progress; chart-repo issue #2 is the binding obligations ledger (incl. Batch 1 lessons-learned).
- **Corrections found in execution** (this plan text deliberately NOT retro-edited; merged code + tracker are authoritative): the peeled-only `ls-remote` UPSTREAM_SHA resolve returns EMPTY on upstream's lightweight tag (use the two-pattern form); `UPSTREAM_SHA` was missing from A2's file list; `rhysd/actionlint` is not a `uses:`-able action (devops-actions wrapper used); `images.yml` dropped the `chart-v*` tags trigger (chart tags don't change image content — release-digest race); wildcard `--set` caused BOTH production failures (cache-ref collision, tagged-ref push-by-digest refusal) — per-target HCL helpers (`cache_from`/`cache_to`/`publish_tags`/`publish_output`) are now the pattern; `setup-helm`'s SHA pin doesn't pin helm (`version:` input required); `ct` runs with `check-version-increment: false` pre-1.0.
- **Three deliberate exceptions to the no-retro-edit convention above**, made at the A3 review bench's request rather than by the author's choice, because leaving them would have propagated errors into work not yet started: Task A3 Step 6's target count (`5` → `6`), Step 4's Flask-Migrate rationale (`check` exists from 4.0.5, not 4.0.6 — the 4.0.6 floor comes from issue #2's acceptance criterion, not from feature availability), and Step 7's smoke command (a bare `--entrypoint python3` hits the system interpreter and fails; the venv interpreter plus the checkout as cwd are the contract). The convention still holds everywhere else: merged code and the tracker remain authoritative.

> **For agentic workers:** implement this plan task-by-task with fresh-context workers and per-task review. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A public repo `jaxzin/indi-allsky-helm` containing multi-arch container images and a Helm chart that deploys indi-allsky on any home Kubernetes cluster, CI-verified end-to-end in kind with the INDI simulator camera.

**Architecture:** Edge pod (indiserver sidecar + full `allsky.py` daemon) pinned by node-contract labels; web (gunicorn + nginx sidecar), MariaDB, and optional mosquitto float. One RWX data PVC carries images + runtime alembic migrations. Images are built with `docker buildx bake` from a pinned upstream tag plus a `patches/` dir; k8s-specific entrypoints replace upstream's sudo/sleep/jq dance.

**Tech Stack:** Helm 3, helm-unittest, chart-testing, kubeconform, kind, docker buildx bake, GitHub Actions (`ubuntu-24.04` + `ubuntu-24.04-arm` runners), ghcr.io, OpenTofu (repo-as-code in jaxzin-infra-bootstrap).

**Companion plan:** the operator's private deployment plan (kept in the author's private workspace) consumes this chart as one instance on the operator's cluster. Spec: [design-spec.md](design-spec.md) in this directory.

## Global Constraints

- Upstream pin: repo `aaronwmorris/indi-allsky`, tag `indi_v2026.08.01` (config level `20260724.0`) — recorded in the `UPSTREAM_VERSION` file, the only place the tag lives.
- INDI versions (from upstream `docker/env_template`): core `v2.2.4.2`, 3rd-party `v2.2.4.1`, camera vendor default `supported`.
- Images: `ghcr.io/jaxzin/indi-allsky-{indiserver,daemon,web}` tagged with the upstream tag and `main`; platforms `linux/amd64,linux/arm64`. Container user is uid/gid **10001** (`allsky`), inherited from upstream images.
- Chart: name `indi-allsky`, path `charts/indi-allsky/`, `appVersion: "indi_v2026.08.01"`. Node-contract label keys: `indi-allsky.io/camera`, `indi-allsky.io/sensors`.
- App URL root is `/indi-allsky/`; OIDC callback path is `/indi-allsky/oidc/callback`.
- In-container paths (upstream contract, do not change): checkout `/home/allsky/indi-allsky`, venv `/home/allsky/venv`, flask config `/etc/indi-allsky/flask.json`, data mount `/var/www/html/allsky` (images at `images/`, migrations at `.state/migrations`).
- Flask CLI has no `FLASK_APP`; every `flask`/`config.py`/`usertool.py` invocation MUST run from `/home/allsky/indi-allsky` with the venv activated.
- No secrets in git or CI logs. GPL-3.0 upstream: images ship upstream source; chart/repo code is Apache-2.0 with a NOTICE pointing at upstream.
- Git discipline: work on `claude/*` branches, PR to `main`, the maintainer merges. jaxzin-infra-bootstrap changes follow that repo's existing conventions.
- Workflow security (security review 2026-08-20): pin third-party GitHub Actions to commit SHAs (official `actions/*` may use major tags); every workflow declares a least-privilege `permissions:` block; secrets are never exposed to jobs triggered by `pull_request`.
- Container hardening (security review 2026-08-21, applies to every task rendering a pod): all containers EXCEPT the device-attached edge containers carry `securityContext: { allowPrivilegeEscalation: false, capabilities: { drop: [ALL] }, seccompProfile: { type: RuntimeDefault } }`, and every pod spec sets `automountServiceAccountToken: false` (nothing in this chart talks to the k8s API). Applies to gunicorn, nginx, static-copy/migrate initContainers, mariadb, the backup CronJob, and mosquitto. Implementers apply per template; SDET/security verify at each task's review.
- Public-repo hygiene: no homelab hostnames or private domains, no tailnet device names, and no homelab-internal paths anywhere in the public repo — use `example.com` placeholders (the maintainer's sensitivity rule; the tailnet *name* is exempt but unneeded here). This constraint applies to these planning documents too if they are ever published: scrub before any migration to the public chart repo. *(This copy is that scrubbed migration — see the provenance note above.)*
- Migrations (the maintainer's decision 2026-08-20, "guarded parity"): runtime autogenerate is retained for v1 but every schema-mutating path takes a `mariadb-dump` first (see A3 `migrate.sh`); CI-committed revisions + an upgrade-path e2e are a hard prerequisite for the first `UPSTREAM_VERSION` bump (issue filed in A10).
- Commit after every green step; commands below show expected output.

---

### Task A1: Create the GitHub repo as code (jaxzin-infra-bootstrap)

The no-manual-IaC invariant applies to repo creation. jaxzin-infra-bootstrap has `tofu/network` but nothing managing GitHub; this task adds a `tofu/github` root module + CI.

**Files (in a clone of `github.com/jaxzin/jaxzin-infra-bootstrap`):**
- Create: `tofu/github/versions.tf`, `tofu/github/repos.tf`
- Create: `.github/workflows/tofu-github.yml`
- Modify: `README.md` (one paragraph documenting `tofu/github`: what it manages; the `GH_REPO_ADMIN_TOKEN` Actions secret it requires — scope (Repository administration Read+Write), expiry policy (≤1 year), and that it is never exposed to `pull_request`-triggered runs (only `push` to `main` applies); plus a pointer that mirroring the token into the maintainer's secret store is a tracked follow-up, not yet done)

**Interfaces:**
- Consumes: the backend configuration pattern from `tofu/network` (read it first; replicate its backend block and state-key naming for a `github` workspace/key).
- Produces: public repo `github.com/jaxzin/indi-allsky-helm` with issues enabled, default branch `main`. Every later task pushes there.

- [ ] **Step 1: Read `tofu/network/*.tf` and the repo README** to learn the backend/state pattern and workflow conventions. Copy the backend stanza style exactly (different state key, e.g. `github/terraform.tfstate`).

- [ ] **Step 2: Write the module**

```hcl
# tofu/github/versions.tf
terraform {
  required_version = ">= 1.7"
  required_providers {
    github = {
      source  = "integrations/github"
      version = "~> 6.6"
    }
  }
  # backend: replicate tofu/network's backend block with state key "github/terraform.tfstate"
}

provider "github" {
  owner = "jaxzin" # token from GITHUB_TOKEN env var in CI
}
```

```hcl
# tofu/github/repos.tf
resource "github_repository" "indi_allsky_helm" {
  name         = "indi-allsky-helm"
  description  = "Helm chart and multi-arch container images for running indi-allsky on Kubernetes"
  visibility   = "public"
  has_issues   = true
  has_wiki     = false
  has_projects = false
  topics       = ["indi-allsky", "helm", "kubernetes", "allsky", "astronomy", "k3s", "raspberry-pi"]

  allow_merge_commit     = true
  allow_squash_merge     = true
  delete_branch_on_merge = true
  vulnerability_alerts   = true
}
```

- [ ] **Step 3: Write the workflow**

```yaml
# .github/workflows/tofu-github.yml
name: tofu-github
on:
  pull_request:
    paths: ["tofu/github/**"]
  push:
    branches: [main]
    paths: ["tofu/github/**"]
permissions:
  contents: read
jobs:
  # PR job: NO secrets in scope — jaxzin-infra-bootstrap is public and PR-authored
  # HCL must never run with the repo-admin PAT (security review 2026-08-20).
  validate:
    if: github.event_name == 'pull_request'
    runs-on: ubuntu-24.04
    defaults:
      run: { working-directory: tofu/github }
    steps:
      - uses: actions/checkout@v4
      - uses: opentofu/setup-opentofu@<pin-to-commit-SHA>   # resolve the current release SHA at implementation
      - run: tofu init -backend=false
      - run: tofu fmt -check && tofu validate
  plan-apply:
    if: github.event_name == 'push'
    runs-on: ubuntu-24.04
    env:
      GITHUB_TOKEN: ${{ secrets.GH_REPO_ADMIN_TOKEN }}
    defaults:
      run: { working-directory: tofu/github }
    steps:
      - uses: actions/checkout@v4
      - uses: opentofu/setup-opentofu@<pin-to-commit-SHA>   # same resolved SHA as the validate job — replace BOTH placeholders
      - run: tofu init
      - run: tofu plan -out=plan.out
      - run: tofu apply -auto-approve plan.out
```

(The full plan output appears in the main-branch run rather than as a PR preview — the accepted trade-off for keeping the admin PAT out of `pull_request` context.)

(If `tofu/network` already has a shared workflow pattern with different auth for the backend, mirror it — backend credentials come from wherever network's workflow gets them.)

- [ ] **Step 4: Run `tofu fmt -check && tofu validate` locally** (no backend/token needed for validate with `tofu init -backend=false`). Expected: clean.

- [ ] **Step 5: Human step (the maintainer):** mint a fine-grained PAT (Repository administration: Read+Write on the jaxzin account, expiry ≤ 1 year) and store it as Actions secret `GH_REPO_ADMIN_TOKEN` in jaxzin-infra-bootstrap. Record length/prefix only. Recommend mirroring into the maintainer's secret store as a follow-up.

- [ ] **Step 6: Commit on `claude/github-repos-as-code`, open PR.** Before opening: confirm every `opentofu/setup-opentofu@<pin-to-commit-SHA>` placeholder (two occurrences in Step 3) has been replaced with a real, resolved commit SHA — a literal placeholder breaks the workflow. PR body: evidence lines (backend pattern source; `tofu fmt -check && tofu validate` output from Step 4). Note for the reviewer: because the PR-triggered `validate` job intentionally has no backend/credentials (security review 2026-08-20), the actual `tofu plan` only runs in the push-triggered `plan-apply` job after merge — the PR body cannot include a pre-merge plan count. After the maintainer merges, verify in the Actions run: the `plan-apply` job's plan step logged `1 to add, 0 to change, 0 to destroy` before auto-apply, then confirm `gh repo view jaxzin/indi-allsky-helm --json visibility,hasIssuesEnabled` → `public`, `true`. Also capture, as evidence on the tracking issue: the PR run showed `validate` executed / `plan-apply` skipped with no secrets in scope, and the push run showed the reverse (SDET gate).

---

### Task A2: Scaffold indi-allsky-helm + base/indiserver images + build pipeline

**Files (in a clone of `github.com/jaxzin/indi-allsky-helm`, all tasks below likewise):**
- Create: `README.md` (stub), `LICENSE` (Apache-2.0), `NOTICE`, `.gitignore`, `UPSTREAM_VERSION`
- Create: `images/docker-bake.hcl`
- Create: `patches/.gitkeep`, `patches/README.md`
- Create: `.github/workflows/images.yml`, `.github/workflows/lint.yml`
- Create: `Makefile`

**Interfaces:**
- Produces: published images `ghcr.io/jaxzin/indi-allsky-indiserver:{main,indi_v2026.08.01}` (multi-arch); bake targets `base`, `indiserver` that Task A3 extends with `daemon`, `web`; `make upstream` convention (checkout upstream at the pin + apply patches into `upstream/`).
- `UPSTREAM_VERSION` contains exactly `indi_v2026.08.01` plus trailing newline; `UPSTREAM_SHA` contains the commit SHA that tag pointed to at pin time (tags are mutable — the SHA is the trust anchor; resolve once with `git ls-remote https://github.com/aaronwmorris/indi-allsky.git 'refs/tags/indi_v2026.08.01^{}'` — the peeled form: upstream's tags are lightweight today, but an annotated tag would otherwise return the tag object, not the commit, and falsely trip the gate). `make upstream` fails if the cloned HEAD does not match.
- Tagged bake targets carry `labels = { "org.opencontainers.image.source" = "https://github.com/jaxzin/indi-allsky-helm" }` so GHCR links packages to the repo.

- [ ] **Step 1: Scaffold repo basics.** `.gitignore` contains `upstream/` (never vendored, checked out by CI/Make). `NOTICE`: "Container images built by this project include indi-allsky (GPL-3.0), © Aaron Morris, https://github.com/aaronwmorris/indi-allsky — source for a given image tag is the upstream tag named by the image tag plus the patches/ directory at the chart repo tag." `patches/README.md`: "Patches applied onto the upstream checkout with `git apply` in lexical order. Each patch must carry a header comment linking the upstream PR that would remove it."

- [ ] **Step 2: Makefile with the upstream-checkout contract**

```makefile
UPSTREAM_REF := $(shell cat UPSTREAM_VERSION)
UPSTREAM_REPO := https://github.com/aaronwmorris/indi-allsky.git

.PHONY: upstream bake-print lint
upstream:
	rm -rf upstream
	git clone --depth 1 --branch $(UPSTREAM_REF) $(UPSTREAM_REPO) upstream
	@test "$$(git -C upstream rev-parse HEAD)" = "$$(cat UPSTREAM_SHA)" || { echo "UPSTREAM_SHA mismatch — tag moved or MITM; refusing to build"; exit 1; }
	set -e; for p in patches/*.patch; do [ -e "$$p" ] || continue; git -C upstream apply ../$$p; done

bake-print: upstream
	docker buildx bake -f images/docker-bake.hcl --print

lint:
	hadolint images/*/Dockerfile || true  # becomes strict in A3 when Dockerfiles exist
	shellcheck images/*/*.sh 2>/dev/null || true
	actionlint
```

- [ ] **Step 3: Write `images/docker-bake.hcl`**

```hcl
variable "REGISTRY" { default = "ghcr.io/jaxzin" }
variable "TAG"      { default = "dev" }
variable "INDI_CORE_VERSION"     { default = "v2.2.4.2" }
variable "INDI_3RDPARTY_VERSION" { default = "v2.2.4.1" }
variable "CAMERA_VENDOR"         { default = "supported" }

group "default" {
  targets = ["indiserver"] # A3 appends "daemon", "web"
}

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
  tags = ["${REGISTRY}/indi-allsky-indiserver:${TAG}"]
}
```

- [ ] **Step 4: Verify the bake graph locally.** Run: `make bake-print`. Expected: JSON showing targets `base` and `indiserver` with `indi.base` context resolving to `target:base`, dockerfiles found under `upstream/docker/`. (Optional slow check: `docker buildx bake -f images/docker-bake.hcl indiserver` builds locally for the host arch — the INDI compile takes ~30+ min; CI is authoritative.)

- [ ] **Step 5: Write `.github/workflows/images.yml`** — per-arch native builds pushed by digest, then a manifest merge (no QEMU for the INDI compile):

```yaml
name: images
on:
  push:
    branches: [main]
    paths: ["images/**", "patches/**", "UPSTREAM_VERSION", ".github/workflows/images.yml"]
    tags: ["chart-v*"]
  workflow_dispatch: {}
permissions:
  contents: read
  packages: write
env:
  REGISTRY: ghcr.io/jaxzin
jobs:
  build:
    strategy:
      matrix:
        include:
          - { runner: ubuntu-24.04,     arch: amd64 }
          - { runner: ubuntu-24.04-arm, arch: arm64 }
    runs-on: ${{ matrix.runner }}
    steps:
      - uses: actions/checkout@v4
      - run: make upstream
      - uses: docker/setup-buildx-action@<pin-to-commit-SHA>
      - uses: docker/login-action@<pin-to-commit-SHA>
        with: { registry: ghcr.io, username: '${{ github.actor }}', password: '${{ secrets.GITHUB_TOKEN }}' }
      - name: Bake and push by digest
        run: |
          docker buildx bake -f images/docker-bake.hcl \
            --set "*.platform=linux/${{ matrix.arch }}" \
            --set "*.output=type=image,push-by-digest=true,push=true,name-canonical=true" \
            --metadata-file bake-meta-${{ matrix.arch }}.json
      - uses: actions/upload-artifact@v4
        with: { name: 'bake-meta-${{ matrix.arch }}', path: 'bake-meta-${{ matrix.arch }}.json' }
  merge:
    needs: build
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
      - uses: actions/download-artifact@v4
        with: { pattern: 'bake-meta-*', merge-multiple: true }
      - uses: docker/login-action@<pin-to-commit-SHA>
        with: { registry: ghcr.io, username: '${{ github.actor }}', password: '${{ secrets.GITHUB_TOKEN }}' }
      - name: Create multi-arch manifests
        run: |
          UPSTREAM_TAG="$(cat UPSTREAM_VERSION)"
          for image in indiserver daemon web; do
            AMD=$(jq -r --arg t "$image" '.[$t]["containerimage.digest"] // empty' bake-meta-amd64.json)
            ARM=$(jq -r --arg t "$image" '.[$t]["containerimage.digest"] // empty' bake-meta-arm64.json)
            [ -z "$AMD" ] && continue   # target not defined yet (A2 has only indiserver)
            docker buildx imagetools create \
              -t "$REGISTRY/indi-allsky-$image:main" \
              -t "$REGISTRY/indi-allsky-$image:$UPSTREAM_TAG" \
              "$REGISTRY/indi-allsky-$image@$AMD" \
              "$REGISTRY/indi-allsky-$image@$ARM"
          done
```

Note: bake metadata keys are target names (`indiserver`, later `daemon`/`web`); the loop names images by target. `base` is intentionally not pushed with a friendly tag.

- [ ] **Step 6: Write `.github/workflows/lint.yml`** — `actionlint`, `shellcheck images/**/*.sh`, `hadolint images/**/Dockerfile*` on every PR (rhysd/actionlint, ludeeus/action-shellcheck, hadolint/hadolint-action with `recursive: true` — each pinned to a resolved commit SHA per Global Constraints, never `@master`/major tags). Declare `permissions: { contents: read }`.

- [ ] **Step 7: Run `actionlint` locally.** Expected: clean.

- [ ] **Step 8: Commit on `claude/scaffold-and-images`, push, open PR.** NOTE (security, 2026-08-21): the repo was created with `auto_init = true` (an initial commit exists on `main`) and a `non_fast_forward` ruleset — clone and branch from that initial commit and push normally; a force-push over it will be rejected, and that is by design. After merge, verify the `images` run is green on both runners and `docker buildx imagetools inspect ghcr.io/jaxzin/indi-allsky-indiserver:main` shows `linux/amd64` and `linux/arm64`.

- [ ] **Step 9: Human step (the maintainer): make the GHCR packages public.** New GHCR packages default to private and GitHub exposes no API for user-package visibility — after the first publish, flip each `indi-allsky-*` package to public in the GitHub Packages UI (repeat once for `daemon`/`web` after A3). Verified naturally by A9: kind pulls the images anonymously, so a private package fails the e2e.

---

### Task A3: daemon and web images (k8s entrypoints)

Overlay images on the upstream-built ones: strip passwordless sudo, replace entrypoints (no sleeps, no `sudo chown`, OIDC env support, migrations moved out of web startup).

**Files:**
- Create: `images/daemon/Dockerfile`, `images/web/Dockerfile`
- Create: `images/shared/render-flask-config.sh`
- Create: `images/daemon/entrypoint-daemon.sh`
- Create: `images/web/entrypoint-web.sh`, `images/web/migrate.sh`
- Modify: `images/docker-bake.hcl` (add `daemon-upstream`, `web-upstream`, `daemon`, `web` targets; extend `group "default"`)

**Interfaces:**
- Consumes: bake targets `base` from A2; upstream Dockerfiles `docker/Dockerfile.capture` and `docker/Dockerfile.gunicorn`.
- Produces: images `ghcr.io/jaxzin/indi-allsky-daemon`, `ghcr.io/jaxzin/indi-allsky-web`. **Container env contract consumed by the chart (Tasks A5–A7):**
  - DB: `MARIADB_USER`, `MARIADB_PASSWORD`, `MARIADB_DATABASE`, `INDIALLSKY_MARIADB_HOST`, `INDIALLSKY_MARIADB_PORT`, `INDIALLSKY_MARIADB_SSL`, `INDIALLSKY_MARIADB_CHARSET`, `INDIALLSKY_MARIADB_COLLATION`
  - Flask: `INDIALLSKY_FLASK_SECRET_KEY`, `INDIALLSKY_FLASK_PASSWORD_KEY`, `INDIALLSKY_FLASK_AUTH_ALL_VIEWS`, `INDIALLSKY_IMAGE_FOLDER`, `INDIALLSKY_MIGRATION_FOLDER`
  - OIDC (all optional): `INDIALLSKY_OIDC_ENABLE`, `INDIALLSKY_OIDC_PROVIDER_NAME`, `INDIALLSKY_OIDC_CLIENT_ID`, `INDIALLSKY_OIDC_CLIENT_SECRET`, `INDIALLSKY_OIDC_DISCOVERY_ENDPOINT`, `INDIALLSKY_OIDC_USERNAME_CLAIM`, `INDIALLSKY_OIDC_ALLOWED_GROUPS` (JSON array string), `INDIALLSKY_OIDC_ADMIN_GROUPS` (JSON array string), `INDIALLSKY_OIDC_AUTO_LOGIN`, `INDIALLSKY_LOCAL_AUTH_ENABLE`
  - Seeding (web migrate only): `INDIALLSKY_WEB_USER`, `INDIALLSKY_WEB_PASS`, `INDIALLSKY_WEB_NAME`, `INDIALLSKY_WEB_EMAIL`, `INDIALLSKY_CONFIG_OVERLAY` (image default `/etc/indi-allsky/config-overlay.json`; A5 deliberately overrides it to the separately projected `/etc/indi-allsky-overlay/config-overlay.json`)
  - `migrate.sh` is the web image's migration/seed command (used as an initContainer command); `entrypoint-daemon.sh` waits for bootstrap via `config.py user_count`.
  - Both entrypoints write `flask.json` to `/etc/indi-allsky` — the chart must mount an emptyDir there.

- [ ] **Step 1: Write `images/shared/render-flask-config.sh`**

```bash
#!/bin/bash
# Renders /etc/indi-allsky/flask.json from the upstream template + env.
# Replaces upstream's start-script jq passes; adds OIDC keys (not env-drivable upstream).
set -o errexit
set -o nounset

ALLSKY_DIRECTORY="/home/allsky/indi-allsky"
ALLSKY_ETC="/etc/indi-allsky"

CHARSET="${INDIALLSKY_MARIADB_CHARSET:-utf8mb4}"
COLLATION="${INDIALLSKY_MARIADB_COLLATION:-utf8mb4_unicode_ci}"
if [ "${INDIALLSKY_MARIADB_SSL:-false}" == "true" ]; then
    SQLALCHEMY_DATABASE_URI="mysql+mysqlconnector://${MARIADB_USER}:${MARIADB_PASSWORD}@${INDIALLSKY_MARIADB_HOST}:${INDIALLSKY_MARIADB_PORT}/${MARIADB_DATABASE}?ssl_ca=/etc/ssl/certs/ca-certificates.crt&ssl_verify_identity&charset=${CHARSET}&collation=${COLLATION}"
else
    SQLALCHEMY_DATABASE_URI="mysql+mysqlconnector://${MARIADB_USER}:${MARIADB_PASSWORD}@${INDIALLSKY_MARIADB_HOST}:${INDIALLSKY_MARIADB_PORT}/${MARIADB_DATABASE}?charset=${CHARSET}&collation=${COLLATION}"
fi

jq \
 --arg  sqlalchemy_database_uri "$SQLALCHEMY_DATABASE_URI" \
 --arg  image_folder            "${INDIALLSKY_IMAGE_FOLDER:-/var/www/html/allsky/images}" \
 --arg  migration_folder        "${INDIALLSKY_MIGRATION_FOLDER:-/var/www/html/allsky/.state/migrations}" \
 --argjson auth_all_views       "${INDIALLSKY_FLASK_AUTH_ALL_VIEWS:-false}" \
 --arg  secret_key              "$INDIALLSKY_FLASK_SECRET_KEY" \
 --arg  password_key            "$INDIALLSKY_FLASK_PASSWORD_KEY" \
 --argjson oidc_enable          "${INDIALLSKY_OIDC_ENABLE:-false}" \
 --arg  oidc_provider_name      "${INDIALLSKY_OIDC_PROVIDER_NAME:-}" \
 --arg  oidc_client_id          "${INDIALLSKY_OIDC_CLIENT_ID:-}" \
 --arg  oidc_client_secret      "${INDIALLSKY_OIDC_CLIENT_SECRET:-}" \
 --arg  oidc_discovery          "${INDIALLSKY_OIDC_DISCOVERY_ENDPOINT:-}" \
 --arg  oidc_username_claim     "${INDIALLSKY_OIDC_USERNAME_CLAIM:-preferred_username}" \
 --argjson oidc_allowed_groups  "${INDIALLSKY_OIDC_ALLOWED_GROUPS:-[]}" \
 --argjson oidc_admin_groups    "${INDIALLSKY_OIDC_ADMIN_GROUPS:-[]}" \
 --argjson oidc_auto_login      "${INDIALLSKY_OIDC_AUTO_LOGIN:-false}" \
 --argjson local_auth_enable    "${INDIALLSKY_LOCAL_AUTH_ENABLE:-true}" \
 '.SQLALCHEMY_DATABASE_URI = $sqlalchemy_database_uri
  | .INDI_ALLSKY_DOCROOT = "/var/www/html/allsky"
  | .INDI_ALLSKY_IMAGE_FOLDER = $image_folder
  | .MIGRATION_FOLDER = $migration_folder
  | .INDI_ALLSKY_AUTH_ALL_VIEWS = $auth_all_views
  | .SECRET_KEY = $secret_key
  | .PASSWORD_KEY = $password_key
  | .OIDC_ENABLE = $oidc_enable
  | .OIDC_PROVIDER_NAME = $oidc_provider_name
  | .OIDC_CLIENT_ID = $oidc_client_id
  | .OIDC_CLIENT_SECRET = $oidc_client_secret
  | .OIDC_DISCOVERY_ENDPOINT = $oidc_discovery
  | .OIDC_USERNAME_CLAIM = $oidc_username_claim
  | .OIDC_ALLOWED_GROUPS = $oidc_allowed_groups
  | .OIDC_ADMIN_GROUPS = $oidc_admin_groups
  | .OIDC_AUTO_LOGIN = $oidc_auto_login
  | .LOCAL_AUTH_ENABLE = $local_auth_enable' \
 "${ALLSKY_DIRECTORY}/flask.json_template" > "${ALLSKY_ETC}/flask.json"

chmod 660 "${ALLSKY_ETC}/flask.json"
json_pp < "${ALLSKY_ETC}/flask.json" >/dev/null
```

(Note: `OIDC_AUTO_LOGIN` is honored by `auth_views.py:76` though absent from the template — jq adds the key.)

- [ ] **Step 2: Write `images/web/migrate.sh`** (initContainer command — migrations, bootstrap, config overlay, optional admin seed)

```bash
#!/bin/bash
set -o errexit
set -o nounset

/home/allsky/render-flask-config.sh
cd /home/allsky/indi-allsky
# shellcheck disable=SC1091
source /home/allsky/venv/bin/activate

echo "Waiting for database ${INDIALLSKY_MARIADB_HOST}:${INDIALLSKY_MARIADB_PORT}"
until python3 -c "import socket; socket.create_connection(('${INDIALLSKY_MARIADB_HOST}', int('${INDIALLSKY_MARIADB_PORT}')), 3)" 2>/dev/null; do
    sleep 3
done

# Alembic revisions are runtime-generated (upstream ships none); MIGRATION_FOLDER
# must persist on the shared data PVC or `upgrade head` cannot find prior revisions.
MIGRATION_FOLDER="${INDIALLSKY_MIGRATION_FOLDER:-/var/www/html/allsky/.state/migrations}"
mkdir -p "$(dirname "$MIGRATION_FOLDER")"
if [[ ! -d "$MIGRATION_FOLDER" ]]; then
    flask db init
fi

# Guarded migrations (the maintainer's decision 2026-08-20; ordering per architect review):
# apply pending revisions FIRST — alembic's `check` and `revision --autogenerate`
# both error against a behind-head DB, which is exactly the upgrade case — then
# dump + autogenerate only when the models genuinely differ from the live schema.
# `flask db check` runs unredirected so its reason is visible in logs; a false
# non-zero still lands in the dump-guarded branch. The web image pins
# Flask-Migrate>=4.0.6 so the subcommand always exists. CI-committed revisions
# replace all of this before the first UPSTREAM_VERSION bump (tracked issue).
flask db upgrade head

if flask db check; then
    echo "Schema matches models; no migration needed"
else
    echo "Model changes detected; generating guarded migration"
    if [ "${INDIALLSKY_PRE_MIGRATE_DUMP:-true}" == "true" ]; then
        # Safety property: no schema mutation without a fresh dump. Disable via
        # migrations.preMigrateDump=false only for least-privilege external DBs
        # with DBA-managed backups. --single-transaction avoids read-locking the
        # catalog against the running daemon.
        # Image fallback retained for standalone compatibility. A5 always sets
        # INDIALLSKY_BACKUP_DIR to /var/www/html/.state/backups, a sibling of
        # the nginx docroot on the shared parent mount.
        DUMP_DIR="${INDIALLSKY_BACKUP_DIR:-/var/www/html/allsky/.state/backups}"
        mkdir -p "$DUMP_DIR"
        MYSQL_PWD="$MARIADB_PASSWORD" mariadb-dump \
            --single-transaction --no-tablespaces \
            -h "$INDIALLSKY_MARIADB_HOST" -P "$INDIALLSKY_MARIADB_PORT" \
            -u "$MARIADB_USER" "$MARIADB_DATABASE" \
            | gzip > "$DUMP_DIR/pre-migrate_$(date +%Y%m%d_%H%M%S).sql.gz"
        ls -1t "$DUMP_DIR"/pre-migrate_*.sql.gz | tail -n +8 | xargs -r rm --
    fi
    flask db revision --autogenerate
    flask db upgrade head
fi

./config.py bootstrap || true   # exits 1 if config already exists

# Apply the GitOps-owned config overlay (deep merge over the current config)
# Image fallback retained for standalone compatibility; A5 sets the separate
# projected chart path /etc/indi-allsky-overlay/config-overlay.json.
OVERLAY="${INDIALLSKY_CONFIG_OVERLAY:-/etc/indi-allsky/config-overlay.json}"
if [[ -f "$OVERLAY" ]]; then
    TMP_DUMP=$(mktemp --suffix=.json)
    TMP_MERGED=$(mktemp --suffix=.json)
    ./config.py dump > "$TMP_DUMP"
    jq -s '.[0] * .[1]' "$TMP_DUMP" "$OVERLAY" > "$TMP_MERGED"
    ./config.py load -c "$TMP_MERGED" --force
    rm -f "$TMP_DUMP" "$TMP_MERGED"
fi

# Seed a local admin only when local auth is on and credentials are provided
if [ "${INDIALLSKY_LOCAL_AUTH_ENABLE:-true}" == "true" ] && [ -n "${INDIALLSKY_WEB_USER:-}" ]; then
    USER_COUNT=$(./config.py user_count)
    if [ "$USER_COUNT" -le 1 ]; then  # only the internal 'system' user exists
        ./misc/usertool.py adduser -u "$INDIALLSKY_WEB_USER" -p "$INDIALLSKY_WEB_PASS" -f "${INDIALLSKY_WEB_NAME:-Admin}" -e "${INDIALLSKY_WEB_EMAIL:-admin@example.com}"
        ./misc/usertool.py setadmin -u "$INDIALLSKY_WEB_USER"
    fi
fi
echo "migrate.sh complete"
```

- [ ] **Step 3: Write `images/web/entrypoint-web.sh` and `images/daemon/entrypoint-daemon.sh`**

```bash
#!/bin/bash
# entrypoint-web.sh
set -o errexit
set -o nounset

/home/allsky/render-flask-config.sh
cd /home/allsky/indi-allsky
# shellcheck disable=SC1091
source /home/allsky/venv/bin/activate

export GUNICORN_ERROR_LOG_HANDLER=wsgi
export INDIALLSKY_DOCKER=1
# Deliberately leave FORWARDED_ALLOW_IPS unset. Gunicorn's localhost-only
# default matches the nginx sidecar topology; the chart must not widen it.

exec gunicorn \
    --bind 0.0.0.0:8000 \
    --worker-class gthread \
    --threads 8 \
    --timeout 180 \
    --umask 0022 \
    --log-level info \
    indi_allsky.wsgi
```

```bash
#!/bin/bash
# entrypoint-daemon.sh
set -o errexit
set -o nounset

/home/allsky/render-flask-config.sh
cd /home/allsky/indi-allsky
# shellcheck disable=SC1091
source /home/allsky/venv/bin/activate

# Wait until migrations + config bootstrap (web migrate initContainer) are done.
# user_count fails while the schema/bootstrap is incomplete.
echo "Waiting for schema bootstrap"
until ./config.py user_count >/dev/null 2>&1; do
    sleep 5
done

if [ -n "${CAPTURE_TMPDIR:-}" ]; then
    export TMPDIR="$CAPTURE_TMPDIR"
fi
export INDIALLSKY_DOCKER=1

if [ "${INDIALLSKY_DARK_CAPTURE_ENABLE:-false}" == "true" ]; then
    exec ./darks.py \
        --bitmax "${INDIALLSKY_DARK_CAPTURE_BITMAX:-16}" \
        "${INDIALLSKY_DARK_CAPTURE_DAYTIME:-}" \
        "${INDIALLSKY_DARK_CAPTURE_MODE:-average}"
else
    exec ./allsky.py --log stderr run
fi
```

- [ ] **Step 4: Write the overlay Dockerfiles**

```dockerfile
# images/daemon/Dockerfile
FROM daemon.upstream
USER root
RUN rm -f /etc/sudoers.d/* && rm -f /etc/sudoers
COPY --chown=allsky:allsky --chmod=755 shared/render-flask-config.sh daemon/entrypoint-daemon.sh /home/allsky/
USER allsky
WORKDIR /home/allsky
ENTRYPOINT ["/home/allsky/entrypoint-daemon.sh"]
```

```dockerfile
# images/web/Dockerfile
FROM web.upstream
USER root
RUN rm -f /etc/sudoers.d/* && rm -f /etc/sudoers
# mariadb-dump for the guarded pre-migrate backup in migrate.sh
RUN apt-get update && apt-get install -y --no-install-recommends mariadb-client && rm -rf /var/lib/apt/lists/*
# `flask db check` (the migrate.sh guard) already exists in Flask-Migrate 4.0.5,
# which is upstream's declared floor — verified: 4.0.5 exposes `check` as a click
# command in flask_migrate.cli. So 4.0.6 is not the earliest version carrying the
# guard; the floor value comes from the binding acceptance criterion on issue #2,
# a conservative margin above the earliest supporting version. The pin's purpose
# is to state the dependency explicitly so a future upstream floor change cannot
# silently remove the guard; it is a no-op when the resolved version already
# satisfies it.
RUN /home/allsky/venv/bin/pip install --no-cache-dir 'Flask-Migrate>=4.0.6'
COPY --chown=allsky:allsky --chmod=755 shared/render-flask-config.sh web/entrypoint-web.sh web/migrate.sh /home/allsky/
USER allsky
WORKDIR /home/allsky
EXPOSE 8000
ENTRYPOINT ["/home/allsky/entrypoint-web.sh"]
```

- [ ] **Step 5: Extend `images/docker-bake.hcl`**

```hcl
# replace: group "default" { targets = ["indiserver", "daemon", "web"] }

target "daemon-upstream" {
  context    = "upstream"
  dockerfile = "docker/Dockerfile.capture"
  contexts   = { "indi.base" = "target:base" }
  args       = { TZ = "UTC" }
}

target "web-upstream" {
  context    = "upstream"
  dockerfile = "docker/Dockerfile.gunicorn"
  args       = { TZ = "UTC" }
}

target "daemon" {
  context    = "images"
  dockerfile = "daemon/Dockerfile"
  contexts   = { "daemon.upstream" = "target:daemon-upstream" }
  tags       = ["${REGISTRY}/indi-allsky-daemon:${TAG}"]
}

target "web" {
  context    = "images"
  dockerfile = "web/Dockerfile"
  contexts   = { "web.upstream" = "target:web-upstream" }
  tags       = ["${REGISTRY}/indi-allsky-web:${TAG}"]
}
```

- [ ] **Step 6: Lint.** Run: `shellcheck images/shared/*.sh images/daemon/*.sh images/web/*.sh && hadolint images/daemon/Dockerfile images/web/Dockerfile && make bake-print`. Expected: clean; bake graph shows 6 targets (`base`, `indiserver`, `daemon-upstream`, `web-upstream`, `daemon`, `web`).

- [ ] **Step 7: Commit on `claude/k8s-images`, PR, merge.** Verify images CI green; `docker buildx imagetools inspect ghcr.io/jaxzin/indi-allsky-daemon:main` shows both arches. Smoke: `docker run --rm -w /home/allsky/indi-allsky --entrypoint /home/allsky/venv/bin/python3 ghcr.io/jaxzin/indi-allsky-web:main -c "import indi_allsky; print('ok')"` → `ok`. (A bare `--entrypoint python3` runs the *system* interpreter, which cannot import `indi_allsky`; the venv interpreter and the checkout as cwd are both part of the contract.)

---

### Task A4: Chart skeleton, values contract, PVC, PriorityClass, chart CI

**Files:**
- Create: `charts/indi-allsky/Chart.yaml`, `charts/indi-allsky/values.yaml`, `charts/indi-allsky/templates/_helpers.tpl`, `charts/indi-allsky/templates/pvc-data.yaml`, `charts/indi-allsky/templates/priorityclass.yaml`, `charts/indi-allsky/.helmignore`
- Create: `charts/indi-allsky/tests/pvc_test.yaml`, `charts/indi-allsky/tests/priorityclass_test.yaml`
- Create: `.github/workflows/chart-ci.yml`, `ct.yaml`

**Interfaces:**
- Produces (consumed by every later task): helper names `indi-allsky.fullname`, `indi-allsky.labels`, `indi-allsky.selectorLabels` (component-suffixed via `indi-allsky.componentLabels`), `indi-allsky.dataPvcName`, `indi-allsky.envSecretName`, `indi-allsky.envConfigMapName`, `indi-allsky.dbHost`; the complete `values.yaml` below is THE values contract — later tasks must not invent keys absent from it.

- [ ] **Step 1: Chart.yaml**

```yaml
apiVersion: v2
name: indi-allsky
description: indi-allsky on Kubernetes — capture pinned to the camera node, everything else floats
type: application
version: 0.1.0
appVersion: "indi_v2026.08.01"
kubeVersion: ">=1.26.0-0"
home: https://github.com/jaxzin/indi-allsky-helm
sources:
  - https://github.com/jaxzin/indi-allsky-helm
  - https://github.com/aaronwmorris/indi-allsky
```

- [ ] **Step 2: values.yaml (complete public contract)**

```yaml
image:
  registry: ghcr.io/jaxzin
  tag: ""          # defaults to .Chart.AppVersion
  # Optional per-image digest pins (architect review 2026-08-20): when set, the
  # reference becomes repo@sha256:… and `tag` is ignored for that image. Tags are
  # mutable; digests are the supply-chain control for the privileged edge pod.
  # Each chart release publishes its image digests in the release notes.
  digests:
    indiserver: ""
    daemon: ""
    web: ""
  pullPolicy: IfNotPresent
  pullSecrets: []

nodeContract:
  cameraLabel: indi-allsky.io/camera
  sensorsLabel: indi-allsky.io/sensors

edge:
  priorityClass:
    create: true
    value: 1000000
  # Guaranteed QoS: set requests == limits (documented; not enforced)
  resources:
    requests: { cpu: "1", memory: 1Gi }
    limits:   { cpu: "1", memory: 1Gi }
  tolerations: []
  podAnnotations: {}       # e.g. Reloader annotations so credential rotation rolls the pod
  # gids granted in hostpath devices mode for /dev access (dialout, gpio, i2c on
  # Raspberry Pi OS/Debian defaults) — adjust to your node OS's group ids
  supplementalGroups: [20, 997, 998]
  # Optional capture-freshness liveness: restarts the pod when latest.jpg goes
  # stale (missing file counts as stale — deliberately fail-closed, so do NOT
  # enable before the first frame exists). OFF by default — long exposures,
  # disabled daytime capture, or darks mode make a static threshold false-positive;
  # enable with a maxAgeSeconds comfortably above your longest capture cadence.
  freshnessProbe:
    enabled: false
    maxAgeSeconds: 900
  sensors:
    enabled: true          # adds sensorsLabel to nodeSelector; mounts sensor devices
  devices:
    mode: hostpath         # hostpath | device-plugin | none
    camera:
      hostPaths: ["/dev/bus/usb"]
      resources: {}        # device-plugin mode, e.g. {squat.ai/asi-camera: 1}
    sensors:
      hostPaths: ["/dev/i2c-1", "/dev/gpiochip0", "/sys/bus/w1"]
      resources: {}
  darks:
    enabled: false         # runs darks.py instead of capture (maintenance mode)

indiserver:
  mode: sidecar            # sidecar | external
  ccdDriver: indi_simulator_ccd
  gpsDriver: ""
  external:
    host: ""
    port: 7624
  resources:
    requests: { cpu: 250m, memory: 256Mi }
    limits:   { cpu: 250m, memory: 256Mi }

web:
  # replicas is intentionally not exposed: migrations + config seeding assume 1
  nodeSelector: {}
  podAnnotations: {}       # e.g. Reloader annotations for credential rotation
  nginx:
    # The static/proxy sidecar image — a values key so it can be digest-pinned,
    # mirrored, or CVE-patched without forking the chart (security review
    # 2026-08-20: this container terminates ingress traffic and mounts the data PVC).
    image: nginx:1.29-alpine
  resources: {}
  authAllViews: false
  service:
    port: 8080
  ingress:
    enabled: false
    className: ""
    host: allsky.example.com
    annotations: {}
    tls: []                # optional; omit when the cluster has a default cert

# Deep-merged over the app's DB config by the migrate initContainer on each
# deploy. Keys here are GitOps-owned; everything else stays UI-owned.
# INDI_SERVER / INDI_PORT / IMAGE_FOLDER are chart-managed — do not set here.
appConfig: {}

migrations:
  # Take a mariadb-dump before any schema-mutating migration (guarded parity,
  # 2026-08-20). Disable ONLY for external databases with least-privilege users
  # and DBA-managed backups — you are then accepting unguarded autogenerate DDL.
  preMigrateDump: true

oidc:
  enabled: false
  providerName: ""
  clientId: ""
  clientSecret: ""         # dev only — prefer credentials.existingSecret
  discoveryEndpoint: ""
  usernameClaim: preferred_username
  allowedGroups: []
  adminGroups: []
  autoLogin: false
  # Renders/hides the local username+password login form. Upstream keeps the POST
  # handler active regardless — but when this is false the chart seeds no local
  # admin (see adminUser), so no local credential exists to use against it.
  localAuth: true

# Local admin seeded only when oidc.localAuth is true AND adminUser.username set
adminUser:
  username: ""
  name: "Admin"
  email: "admin@example.com"

credentials:
  # Either provide an existingSecret with the keys below, or set inline values (dev only).
  # Required keys: INDIALLSKY_FLASK_SECRET_KEY, INDIALLSKY_FLASK_PASSWORD_KEY, MARIADB_PASSWORD.
  # Optional keys: INDIALLSKY_OIDC_CLIENT_ID, INDIALLSKY_OIDC_CLIENT_SECRET,
  #   INDIALLSKY_OIDC_DISCOVERY_ENDPOINT, INDIALLSKY_WEB_PASS.
  # Mechanism: pods use envFrom [ConfigMap, Secret] in that order, so a key present in
  # the Secret wins over / completes what the ConfigMap renders from plain values —
  # OIDC client id and discovery endpoint may therefore live in either place.
  existingSecret: ""
  flaskSecretKey: ""
  flaskPasswordKey: ""     # Fernet key — losing it makes stored app passwords unrecoverable
  mariadbPassword: ""
  adminPassword: ""

storage:
  retentionPolicy: Retain
  data:
    # RWX required whenever edge and web can land on different nodes
    existingClaim: ""
    storageClassName: ""
    accessModes: [ReadWriteMany]
    size: 100Gi

mariadb:
  enabled: true
  image: mariadb:11.8
  database: indi_allsky
  username: indi_allsky
  nodeSelector: {}
  resources: {}
  persistence:
    storageClassName: ""
    size: 8Gi
  backup:
    enabled: false
    schedule: "20 4 * * *"
    retentionDays: 14

externalDatabase:
  host: ""
  port: 3306
  database: indi_allsky
  username: indi_allsky

mosquitto:
  enabled: false
  image: eclipse-mosquitto:2.0
  resources: {}

timezone: UTC

discovery:
  nfd:
    # Requires Node Feature Discovery installed in the cluster. NFD's usb source
    # only reports device classes in its deviceClassWhitelist — you may need to
    # extend the NFD worker config for your camera. See docs/node-contract.md.
    enabled: false
    usbVendorIds: ["03c3", "1618"]   # ZWO, QHY — extend via values
```

- [ ] **Step 3: _helpers.tpl**

The implemented helper layer keeps labels/selectors and image digest selection
centralized. Generated object names go through one collision-safe
`resourceName` helper: DNS-label normalization and truncation append an
eight-character hash derived from the original candidate, while preserving the
semantic suffix. Dedicated helpers (`dataPvcName`, `envSecretName`,
`envConfigMapName`, `overlayConfigMapName`, `mariadbName`,
`mariadbServiceName`, `mariadbDataPvcName`, `mariadbRootSecretName`, and
`backupCronJobName`) are the only names consumed by templates and
cross-resource references. CronJob names use a 52-character ceiling; all other
generated names use 63. Existing Secret and PVC names are validated as DNS
subdomains before their helpers return them.

- [ ] **Step 4: pvc-data.yaml and priorityclass.yaml**

```yaml
# templates/pvc-data.yaml
{{- if not .Values.storage.data.existingClaim }}
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ include "indi-allsky.dataPvcName" . }}
  labels: {{- include "indi-allsky.labels" . | nindent 4 }}
spec:
  accessModes: {{- toYaml .Values.storage.data.accessModes | nindent 4 }}
  {{- with .Values.storage.data.storageClassName }}
  storageClassName: {{ . | quote }}
  {{- end }}
  resources:
    requests:
      storage: {{ .Values.storage.data.size | quote }}
{{- end }}
```

```yaml
# templates/priorityclass.yaml
{{- if .Values.edge.priorityClass.create }}
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: {{ include "indi-allsky.resourceName" (dict "ctx" . "suffix" "capture" "maxLength" 63) }}
  labels: {{- include "indi-allsky.labels" . | nindent 4 }}
value: {{ .Values.edge.priorityClass.value }}
globalDefault: false
description: "indi-allsky capture — outranks ordinary workloads on the camera node"
{{- end }}
```

- [ ] **Step 5: Write failing unit tests first** (`helm plugin install https://github.com/helm-unittest/helm-unittest` locally)

```yaml
# charts/indi-allsky/tests/pvc_test.yaml
suite: data pvc
templates: [pvc-data.yaml]
tests:
  - it: renders an RWX PVC by default
    asserts:
      - equal: { path: spec.accessModes[0], value: ReadWriteMany }
      - equal: { path: spec.resources.requests.storage, value: 100Gi }
  - it: is omitted when existingClaim is set
    set: { storage.data.existingClaim: my-claim }
    asserts:
      - hasDocuments: { count: 0 }
```

```yaml
# charts/indi-allsky/tests/priorityclass_test.yaml
suite: priority class
templates: [priorityclass.yaml]
tests:
  - it: renders with the configured value
    asserts:
      - equal: { path: value, value: 1000000 }
      - equal: { path: kind, value: PriorityClass }
  - it: can be disabled
    set: { edge.priorityClass.create: false }
    asserts:
      - hasDocuments: { count: 0 }
```

- [ ] **Step 6: Run tests — verify they fail, then pass.** `helm unittest charts/indi-allsky` → fails before templates exist, passes after Step 4. Then `helm lint charts/indi-allsky` → `1 chart(s) linted, 0 chart(s) failed`.

- [ ] **Step 7: chart CI**

```yaml
# ct.yaml
chart-dirs: [charts]
target-branch: main
validate-maintainers: false
```

```yaml
# .github/workflows/chart-ci.yml
name: chart-ci
on:
  pull_request:
    paths: ["charts/**", "e2e/**", ".github/workflows/chart-ci.yml"]
  push:
    branches: [main]
    paths: ["charts/**", "e2e/**"]
permissions:
  contents: read
jobs:
  lint:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - uses: azure/setup-helm@<pin-to-commit-SHA>
      - run: helm plugin install https://github.com/helm-unittest/helm-unittest
      - run: helm unittest charts/indi-allsky
      - uses: helm/chart-testing-action@<pin-to-commit-SHA>
      - run: ct lint --config ct.yaml
      - name: kubeconform
        run: |
          helm template charts/indi-allsky | \
            docker run -i ghcr.io/yannh/kubeconform:latest-alpine \
            -strict -ignore-missing-schemas -summary
  # e2e job added in Task A9
```

- [ ] **Step 8: Seed the living docs** (tech-writer review 2026-08-20 — docs grow with the features, not batched at the end): create `README.md`'s "Node contract" section and `docs/node-contract.md` as real stubs now — the two labels, the camera+sensors same-node constraint and why, and the values keys that express them. A7 extends (devices/host-prep), A8 extends (topologies/NFD caveat), A10 completes.

- [ ] **Step 9: Commit on `claude/chart-skeleton`, PR, merge.** Evidence: chart-ci lint job green.

---

### Task A5: env ConfigMap/Secret, config overlay, MariaDB, backup CronJob

**Files:**
- Create: `charts/indi-allsky/templates/configmap-env.yaml`, `templates/secret-env.yaml`, `templates/configmap-overlay.yaml`
- Create: `templates/secret-mariadb-root.yaml`, `templates/mariadb-statefulset.yaml`, `templates/mariadb-service.yaml`, `templates/mariadb-backup-cronjob.yaml`, `templates/pvc-mariadb.yaml`, `templates/validate.yaml`
- Create: manifest-specific suites under `charts/indi-allsky/tests/` plus a centralized invalid-value suite and validation-wiring guard

**Interfaces:**
- Consumes: helpers + values from A4; container env contract from A3.
- Produces: the plain env ConfigMap (`envConfigMapName`), application Secret
  (`envSecretName`, skipped for `credentials.existingSecret`), isolated root
  Secret (`mariadbRootSecretName`, skipped for its existing-Secret mode),
  overlay ConfigMap (`overlayConfigMapName`, key `config-overlay.json`), and
  headless MariaDB Service (`mariadbServiceName`, port 3306). The suffix-preserving
  helpers, rather than string concatenation, are the naming contract. Pods in
  A6/A7 use the env ConfigMap plus application Secret and project the overlay
  separately at `/etc/indi-allsky-overlay/config-overlay.json` without
  `subPath`.

> **Approved implementation amendment (Batch 3 review bench):** the shared PVC
> is mounted at `/var/www/html`, with app data under `allsky` and backups under
> sibling `.state/backups`; MariaDB root credentials use a separate recoverable
> Secret and file-backed `MARIADB_ROOT_PASSWORD_FILE`; the Service is headless;
> and A6/A7 coordinate through the exact canonical-overlay checksum sentinel at
> `/var/www/html/.state/config-overlay.applied`. These requirements supersede
> the original illustrative excerpts wherever an excerpt is incomplete.

> **Approved storage-lifecycle amendment:** `storage.retentionPolicy` is the
> exact enum `Retain|Delete`, defaulting to `Retain`, and governs both generated
> shared-data and internal-MariaDB PVCs. Both are standalone Helm-managed
> claims and use Helm's keep annotation in `Retain` mode; `Delete` omits it from
> both. This avoids the StatefulSet PVC-retention field, which is not compatible
> with the Kubernetes 1.26 floor. Existing shared claims are never modified,
> and external mode has no MariaDB PVC. PVC size and storage-class scalar sinks
> are validated and quoted to prevent YAML document or sibling-field injection.

- [ ] **Step 1: Failing unit tests**

```yaml
# charts/indi-allsky/tests/env_test.yaml
suite: env configmap + secret + overlay
templates: [configmap-env.yaml, secret-env.yaml, configmap-overlay.yaml]
tests:
  - it: points at in-chart mariadb and sets image folder
    templates: [configmap-env.yaml]
    asserts:
      - equal: { path: data.INDIALLSKY_MARIADB_HOST, value: RELEASE-NAME-indi-allsky-mariadb }
      - equal: { path: data.INDIALLSKY_IMAGE_FOLDER, value: /var/www/html/allsky/images }
      - equal: { path: data.INDIALLSKY_OIDC_ENABLE, value: "false" }
  - it: oidc groups serialize as JSON arrays
    templates: [configmap-env.yaml]
    set:
      oidc: { enabled: true, allowedGroups: [homelab-users], adminGroups: [homelab-admins] }
    asserts:
      - equal: { path: data.INDIALLSKY_OIDC_ALLOWED_GROUPS, value: '["homelab-users"]' }
      - equal: { path: data.INDIALLSKY_OIDC_ADMIN_GROUPS, value: '["homelab-admins"]' }
  - it: secret is omitted with existingSecret
    templates: [secret-env.yaml]
    set: { credentials.existingSecret: indi-allsky-env }
    asserts:
      - hasDocuments: { count: 0 }
  - it: overlay pins INDI_SERVER to localhost in sidecar mode
    templates: [configmap-overlay.yaml]
    asserts:
      - matchRegex: { path: data["config-overlay.json"], pattern: '"INDI_SERVER": "localhost"' }
  - it: overlay uses external indiserver host when configured
    templates: [configmap-overlay.yaml]
    set: { indiserver: { mode: external, external: { host: indiserver.example.com, port: 7624 } } }  # [fixture hostname neutralized in review]
    asserts:
      - matchRegex: { path: data["config-overlay.json"], pattern: '"INDI_SERVER": "indiserver.example.com"' }
  - it: renders external database settings when mariadb is disabled
    templates: [configmap-env.yaml]
    set:
      mariadb.enabled: false
      externalDatabase: { host: db.example.com, port: 3307, database: allsky, username: allsky_user }
    asserts:
      - equal: { path: data.INDIALLSKY_MARIADB_HOST, value: db.example.com }
      - equal: { path: data.INDIALLSKY_MARIADB_PORT, value: "3307" }
      - equal: { path: data.MARIADB_USER, value: allsky_user }
      - equal: { path: data.MARIADB_DATABASE, value: allsky }
  - it: fails with an actionable error when external db host is missing
    templates: [configmap-env.yaml]
    set: { mariadb.enabled: false }
    asserts:
      - failedTemplate: { errorMessage: "externalDatabase.host is required when mariadb.enabled=false" }
```

Run `helm unittest charts/indi-allsky` — expect the new suite to FAIL (templates missing).

- [ ] **Step 2: configmap-env.yaml**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "indi-allsky.envConfigMapName" . }}
  labels: {{- include "indi-allsky.labels" . | nindent 4 }}
data:
  TZ: {{ .Values.timezone | quote }}
  INDIALLSKY_MARIADB_HOST: {{ include "indi-allsky.dbHost" . | quote }}
  INDIALLSKY_MARIADB_PORT: {{ (.Values.mariadb.enabled | ternary 3306 .Values.externalDatabase.port) | quote }}
  INDIALLSKY_MARIADB_SSL: "false"
  MARIADB_USER: {{ (.Values.mariadb.enabled | ternary .Values.mariadb.username .Values.externalDatabase.username) | quote }}
  MARIADB_DATABASE: {{ (.Values.mariadb.enabled | ternary .Values.mariadb.database .Values.externalDatabase.database) | quote }}
  INDIALLSKY_IMAGE_FOLDER: "/var/www/html/allsky/images"
  INDIALLSKY_MIGRATION_FOLDER: "/var/www/html/allsky/.state/migrations"
  INDIALLSKY_PRE_MIGRATE_DUMP: {{ .Values.migrations.preMigrateDump | quote }}
  INDIALLSKY_FLASK_AUTH_ALL_VIEWS: {{ .Values.web.authAllViews | quote }}
  INDIALLSKY_OIDC_ENABLE: {{ .Values.oidc.enabled | quote }}
  INDIALLSKY_OIDC_PROVIDER_NAME: {{ .Values.oidc.providerName | quote }}
  {{- if .Values.oidc.clientId }}
  INDIALLSKY_OIDC_CLIENT_ID: {{ .Values.oidc.clientId | quote }}
  {{- end }}
  {{- if .Values.oidc.discoveryEndpoint }}
  INDIALLSKY_OIDC_DISCOVERY_ENDPOINT: {{ .Values.oidc.discoveryEndpoint | quote }}
  {{- end }}
  INDIALLSKY_OIDC_USERNAME_CLAIM: {{ .Values.oidc.usernameClaim | quote }}
  INDIALLSKY_OIDC_ALLOWED_GROUPS: {{ .Values.oidc.allowedGroups | toJson | quote }}
  INDIALLSKY_OIDC_ADMIN_GROUPS: {{ .Values.oidc.adminGroups | toJson | quote }}
  INDIALLSKY_OIDC_AUTO_LOGIN: {{ .Values.oidc.autoLogin | quote }}
  INDIALLSKY_LOCAL_AUTH_ENABLE: {{ .Values.oidc.localAuth | quote }}
  {{- if .Values.adminUser.username }}
  INDIALLSKY_WEB_USER: {{ .Values.adminUser.username | quote }}
  INDIALLSKY_WEB_NAME: {{ .Values.adminUser.name | quote }}
  INDIALLSKY_WEB_EMAIL: {{ .Values.adminUser.email | quote }}
  {{- end }}
  {{- if .Values.edge.darks.enabled }}
  INDIALLSKY_DARK_CAPTURE_ENABLE: "true"
  {{- end }}
```

- [ ] **Step 3: secret-env.yaml** (rendered only without existingSecret; `required` guards give actionable errors)

```yaml
{{- if not .Values.credentials.existingSecret }}
apiVersion: v1
kind: Secret
metadata:
  name: {{ include "indi-allsky.fullname" . }}-env
  labels: {{- include "indi-allsky.labels" . | nindent 4 }}
type: Opaque
stringData:
  INDIALLSKY_FLASK_SECRET_KEY: {{ required "credentials.flaskSecretKey (or existingSecret) is required" .Values.credentials.flaskSecretKey | quote }}
  INDIALLSKY_FLASK_PASSWORD_KEY: {{ required "credentials.flaskPasswordKey (or existingSecret) is required" .Values.credentials.flaskPasswordKey | quote }}
  MARIADB_PASSWORD: {{ required "credentials.mariadbPassword (or existingSecret) is required" .Values.credentials.mariadbPassword | quote }}
  {{- if .Values.oidc.clientSecret }}
  INDIALLSKY_OIDC_CLIENT_SECRET: {{ .Values.oidc.clientSecret | quote }}
  {{- end }}
  {{- if .Values.credentials.adminPassword }}
  INDIALLSKY_WEB_PASS: {{ .Values.credentials.adminPassword | quote }}
  {{- end }}
{{- end }}
```

- [ ] **Step 4: configmap-overlay.yaml** (chart-managed keys merged over `.Values.appConfig`; chart wins)

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "indi-allsky.overlayConfigMapName" . }}
  labels: {{- include "indi-allsky.labels" . | nindent 4 }}
data:
  config-overlay.json: |
{{- $indiHost := eq .Values.indiserver.mode "sidecar" | ternary "localhost" .Values.indiserver.external.host }}
{{- $indiPort := eq .Values.indiserver.mode "sidecar" | ternary 7624 (int .Values.indiserver.external.port) }}
{{- $managed := dict "INDI_SERVER" $indiHost "INDI_PORT" $indiPort "IMAGE_FOLDER" "/var/www/html/allsky/images" }}
{{ mustMergeOverwrite (deepCopy .Values.appConfig) $managed | toPrettyJson | indent 4 }}
```

- [ ] **Step 5: mariadb-statefulset.yaml, mariadb-service.yaml, mariadb-backup-cronjob.yaml**

```yaml
# templates/mariadb-statefulset.yaml
{{- if .Values.mariadb.enabled }}
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: {{ include "indi-allsky.mariadbName" . }}
  labels: {{- include "indi-allsky.labels" . | nindent 4 }}
spec:
  serviceName: {{ include "indi-allsky.mariadbServiceName" . }}
  replicas: 1
  selector:
    matchLabels: {{- include "indi-allsky.componentLabels" (dict "ctx" . "component" "mariadb") | nindent 6 }}
  template:
    metadata:
      labels: {{- include "indi-allsky.componentLabels" (dict "ctx" . "component" "mariadb") | nindent 8 }}
    spec:
      {{- with .Values.mariadb.nodeSelector }}
      nodeSelector: {{- toYaml . | nindent 8 }}
      {{- end }}
      securityContext:
        fsGroup: 999
      containers:
        - name: mariadb
          image: {{ .Values.mariadb.image }}
          args: ["--character-set-server=utf8mb4", "--collation-server=utf8mb4_unicode_ci"]
          env:
            - name: MARIADB_DATABASE
              value: {{ .Values.mariadb.database | quote }}
            - name: MARIADB_USER
              value: {{ .Values.mariadb.username | quote }}
            - { name: MARIADB_PASSWORD_FILE, value: /run/secrets/app/MARIADB_PASSWORD }
            - { name: MARIADB_ROOT_PASSWORD_FILE, value: /run/secrets/root/MARIADB_ROOT_PASSWORD }
            - { name: MARIADB_ROOT_HOST, value: localhost }
          ports: [{ containerPort: 3306, name: mysql }]
          livenessProbe:
            exec: { command: [healthcheck.sh, --connect, --innodb_initialized] }
            initialDelaySeconds: 30
            periodSeconds: 10
          readinessProbe:
            exec: { command: [healthcheck.sh, --connect, --innodb_initialized] }
            initialDelaySeconds: 10
            periodSeconds: 5
          {{- with .Values.mariadb.resources }}
          resources: {{- toYaml . | nindent 12 }}
          {{- end }}
          volumeMounts: [{ name: database, mountPath: /var/lib/mysql }]
      volumes:
        - name: database
          persistentVolumeClaim:
            claimName: {{ include "indi-allsky.mariadbDataPvcName" . }}
{{- end }}
```

```yaml
# templates/pvc-mariadb.yaml
{{- if .Values.mariadb.enabled }}
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ include "indi-allsky.mariadbDataPvcName" . }}
  {{- if eq .Values.storage.retentionPolicy "Retain" }}
  annotations: { helm.sh/resource-policy: keep }
  {{- end }}
spec:
  accessModes: [ReadWriteOnce]
  {{- with .Values.mariadb.persistence.storageClassName }}
  storageClassName: {{ . | quote }}
  {{- end }}
  resources:
    requests:
      storage: {{ .Values.mariadb.persistence.size | quote }}
{{- end }}
```

```yaml
# templates/mariadb-service.yaml
{{- if .Values.mariadb.enabled }}
apiVersion: v1
kind: Service
metadata:
  name: {{ include "indi-allsky.mariadbServiceName" . }}
  labels: {{- include "indi-allsky.labels" . | nindent 4 }}
spec:
  clusterIP: None
  ports: [{ port: 3306, targetPort: mysql, name: mysql }]
  selector: {{- include "indi-allsky.componentLabels" (dict "ctx" . "component" "mariadb") | nindent 4 }}
{{- end }}
```

```yaml
# templates/mariadb-backup-cronjob.yaml
{{- if and .Values.mariadb.enabled .Values.mariadb.backup.enabled }}
apiVersion: batch/v1
kind: CronJob
metadata:
  name: {{ include "indi-allsky.backupCronJobName" . }}
  labels: {{- include "indi-allsky.labels" . | nindent 4 }}
spec:
  schedule: {{ .Values.mariadb.backup.schedule | quote }}
  concurrencyPolicy: Forbid
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: Never
          securityContext: { runAsUser: 10001, runAsGroup: 10001, fsGroup: 10001 }
          containers:
            - name: dump
              image: {{ .Values.mariadb.image }}
              # Explicit DB fields only; never envFrom and never the root Secret.
              command: [/bin/bash, -c]
              args:
                - |
                  set -Eeuo pipefail
                  umask 077
                  # The implemented script uses mktemp + trap, MYSQL_PWD,
                  # mariadb-dump --single-transaction --quick --no-tablespaces
                  # -- "$DB_DATABASE", gzip/non-empty verification, mode 0600,
                  # a unique atomic rename, a verified-success log, then
                  # prefix-scoped retention for indi-allsky_scheduled_* only.
              volumeMounts: [{ name: data, mountPath: /var/www/html }]
          volumes:
            - name: data
              persistentVolumeClaim: { claimName: {{ include "indi-allsky.dataPvcName" . }} }
{{- end }}
```

- [ ] **Step 6: mariadb unit tests**

```yaml
# charts/indi-allsky/tests/mariadb_test.yaml
suite: mariadb
templates: [mariadb-statefulset.yaml, mariadb-service.yaml, mariadb-backup-cronjob.yaml]
tests:
  # The implemented suites select each manifest independently. They assert the
  # headless Service, isolated root Secret, full pod/container hardening,
  # file-backed credentials, probes, backup command safety/order, external-mode
  # omission, max-length names, and invalid/unset/malformed boundaries. Document
  # counts across a multi-template suite are not used as structural evidence.
```

- [ ] **Step 7: Run `helm unittest charts/indi-allsky` → all suites pass; `helm lint` clean. Commit on `claude/chart-db-env`, PR, merge.** Evidence: chart-ci green.

---

### Task A6: Web deployment (migrate initContainer, nginx sidecar, Service, Ingress)

**Files:**
- Create: `charts/indi-allsky/templates/web-deployment.yaml`, `templates/web-service.yaml`, `templates/web-ingress.yaml`, `templates/configmap-nginx.yaml`
- Create: `charts/indi-allsky/tests/web_test.yaml`

**Interfaces:**
- Consumes: env ConfigMap/Secret + overlay ConfigMap (A5), data PVC (A4), images (A3: `migrate.sh`, `entrypoint-web.sh`).
- Produces: Service `<fullname>-web` on `web.service.port` → nginx 8080; deployment name `<fullname>-web`. The e2e (A9) curls `/indi-allsky/js/latest` through this Service.

> **Binding A5 handoff:** the web pod consumes the application Secret only,
> never the MariaDB root Secret. After `migrate.sh` has completed migration,
> bootstrap, overlay application, and optional admin seeding successfully, its
> migration initContainer writes
> `INDIALLSKY_CONFIG_OVERLAY_SHA256` plus one newline to a temporary file beside
> `INDIALLSKY_CONFIG_OVERLAY_APPLIED_SENTINEL`, then atomically renames it over
> that fixed sentinel. No failure path may update the sentinel.
>
> This checksum orders overlay revisions only. It is not proof that an
> image/schema-only upgrade with unchanged overlay bytes has completed; issue
> #9 owns the general migration-order decision and upgrade-path e2e.

- [ ] **Step 1: Failing unit tests**

```yaml
# charts/indi-allsky/tests/web_test.yaml
suite: web
templates: [web-deployment.yaml, web-service.yaml, web-ingress.yaml, configmap-nginx.yaml]
tests:
  - it: has migrate + static-copy initContainers and two containers
    templates: [web-deployment.yaml]
    asserts:
      - equal: { path: spec.replicas, value: 1 }
      - equal: { path: spec.template.spec.initContainers[0].name, value: migrate }
      - equal: { path: spec.template.spec.initContainers[1].name, value: static-copy }
      - lengthEqual: { path: spec.template.spec.containers, count: 2 }
  - it: nginx passes through x-forwarded-proto
    templates: [configmap-nginx.yaml]
    asserts:
      - matchRegex: { path: data["nginx.conf"], pattern: 'X-Forwarded-Proto \$fwd_proto' }
  - it: ingress renders host and class
    templates: [web-ingress.yaml]
    set: { web.ingress: { enabled: true, className: traefik, host: allsky.example.com } }
    asserts:
      - equal: { path: spec.ingressClassName, value: traefik }
      - equal: { path: spec.rules[0].host, value: allsky.example.com }
  - it: ingress absent by default
    templates: [web-ingress.yaml]
    asserts:
      - hasDocuments: { count: 0 }
```

- [ ] **Step 2: configmap-nginx.yaml** — adapted from upstream `service/nginx_indi-allsky.conf`; the critical delta from upstream: `X-Forwarded-Proto` passes through the ingress value instead of `$scheme` (upstream would downgrade OIDC redirects to `http://` behind TLS-terminating ingress)

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "indi-allsky.fullname" . }}-nginx
  labels: {{- include "indi-allsky.labels" . | nindent 4 }}
data:
  nginx.conf: |
    worker_processes auto;
    pid /tmp/nginx.pid;
    events { worker_connections 512; }
    http {
      include /etc/nginx/mime.types;
      default_type application/octet-stream;
      access_log /dev/stdout;
      error_log /dev/stderr;
      client_body_temp_path /tmp/client_body;
      proxy_temp_path /tmp/proxy;
      fastcgi_temp_path /tmp/fastcgi;
      uwsgi_temp_path /tmp/uwsgi;
      scgi_temp_path /tmp/scgi;
      sendfile on;

      map $http_x_forwarded_proto $fwd_proto {
        default $http_x_forwarded_proto;
        ''      $scheme;
      }

      upstream app { server 127.0.0.1:8000 fail_timeout=0; }

      server {
        listen 8080;
        client_max_body_size 1024m;
        proxy_read_timeout 600s;

        location = / { return 302 /indi-allsky/; }

        location /indi-allsky/images/ {
          alias /var/www/html/allsky/images/;
          autoindex off;
          location ~* \.(jpe?g|png|tiff?|bmp|gif|fits?|webp|jp2|mp4|webm)$ {
            expires 90d;
            add_header Cache-Control "public";
          }
        }

        location /indi-allsky/static/ {
          alias /usr/share/indi-allsky/static/;
          expires 1d;
        }

        location /indi-allsky {
          try_files $uri @app;
        }

        location @app {
          proxy_pass http://app;
          proxy_http_version 1.1;
          proxy_set_header Host $http_host;
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_set_header X-Forwarded-Proto $fwd_proto;
          proxy_set_header Upgrade $http_upgrade;
          proxy_set_header Connection "upgrade";
          proxy_redirect off;
        }
      }
    }
```

- [ ] **Step 3: web-deployment.yaml**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "indi-allsky.fullname" . }}-web
  labels: {{- include "indi-allsky.labels" . | nindent 4 }}
spec:
  replicas: 1
  strategy: { type: Recreate }   # migrate initContainer must not run concurrently
  selector:
    matchLabels: {{- include "indi-allsky.componentLabels" (dict "ctx" . "component" "web") | nindent 6 }}
  template:
    metadata:
      labels: {{- include "indi-allsky.componentLabels" (dict "ctx" . "component" "web") | nindent 8 }}
      annotations:
        {{- with .Values.web.podAnnotations }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
        checksum/env: {{ include (print $.Template.BasePath "/configmap-env.yaml") . | sha256sum }}
        checksum/overlay: {{ include "indi-allsky.overlayChecksum" . }}
        checksum/nginx: {{ include (print $.Template.BasePath "/configmap-nginx.yaml") . | sha256sum }}
    spec:
      {{- with .Values.image.pullSecrets }}
      imagePullSecrets: {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.web.nodeSelector }}
      nodeSelector: {{- toYaml . | nindent 8 }}
      {{- end }}
      securityContext:
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
      initContainers:
        - name: migrate
          image: '{{ include "indi-allsky.image" (dict "ctx" . "name" "web") }}'
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          command: [/home/allsky/migrate.sh]
          envFrom: &webenv
            - configMapRef: { name: {{ include "indi-allsky.envConfigMapName" . }} }
            - secretRef: { name: {{ include "indi-allsky.envSecretName" . }} }
          volumeMounts: &webmounts
            - { name: data, mountPath: /var/www/html }
            - { name: etc, mountPath: /etc/indi-allsky }
            - { name: overlay, mountPath: /etc/indi-allsky-overlay, readOnly: true }
        - name: static-copy
          image: '{{ include "indi-allsky.image" (dict "ctx" . "name" "web") }}'
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          command: [/bin/bash, -ec, "cp -a /home/allsky/indi-allsky/indi_allsky/flask/static/. /static-share/"]
          volumeMounts:
            - { name: static-share, mountPath: /static-share }
      containers:
        - name: gunicorn
          image: '{{ include "indi-allsky.image" (dict "ctx" . "name" "web") }}'
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          envFrom: *webenv
          ports: [{ containerPort: 8000, name: gunicorn }]
          readinessProbe:
            httpGet: { path: /indi-allsky/login, port: 8000 }
            initialDelaySeconds: 15
            periodSeconds: 10
          {{- with .Values.web.resources }}
          resources: {{- toYaml . | nindent 12 }}
          {{- end }}
          volumeMounts: *webmounts
        - name: nginx
          image: {{ .Values.web.nginx.image }}
          ports: [{ containerPort: 8080, name: http }]
          readinessProbe:
            httpGet: { path: /indi-allsky/static/, port: 8080 }
            initialDelaySeconds: 5
          volumeMounts:
            - { name: nginx-conf, mountPath: /etc/nginx/nginx.conf, subPath: nginx.conf }
            - { name: data, mountPath: /var/www/html/allsky, readOnly: true }
            - { name: static-share, mountPath: /usr/share/indi-allsky/static, readOnly: true }
            - { name: nginx-tmp, mountPath: /tmp }
      volumes:
        - name: data
          persistentVolumeClaim: { claimName: {{ include "indi-allsky.dataPvcName" . }} }
        - name: etc
          emptyDir: { medium: Memory, sizeLimit: 1Mi }
        - name: overlay
          configMap: { name: {{ include "indi-allsky.overlayConfigMapName" . }} }
        - name: static-share
          emptyDir: {}
        - name: nginx-conf
          configMap: { name: {{ include "indi-allsky.fullname" . }}-nginx }
        - name: nginx-tmp
          emptyDir: {}
```

(YAML anchors `&webenv`/`*webenv` are valid within a single rendered document and keep initContainer/container env in sync.)

- [ ] **Step 4: web-service.yaml + web-ingress.yaml**

```yaml
# templates/web-service.yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ include "indi-allsky.fullname" . }}-web
  labels: {{- include "indi-allsky.labels" . | nindent 4 }}
spec:
  ports:
    - port: {{ .Values.web.service.port }}
      targetPort: http
      name: http
  selector: {{- include "indi-allsky.componentLabels" (dict "ctx" . "component" "web") | nindent 4 }}
```

```yaml
# templates/web-ingress.yaml
{{- if .Values.web.ingress.enabled }}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ include "indi-allsky.fullname" . }}-web
  labels: {{- include "indi-allsky.labels" . | nindent 4 }}
  {{- with .Values.web.ingress.annotations }}
  annotations: {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  {{- with .Values.web.ingress.className }}
  ingressClassName: {{ . }}
  {{- end }}
  {{- with .Values.web.ingress.tls }}
  tls: {{- toYaml . | nindent 4 }}
  {{- end }}
  rules:
    - host: {{ .Values.web.ingress.host | quote }}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: {{ include "indi-allsky.fullname" . }}-web
                port: { name: http }
{{- end }}
```

- [ ] **Step 5: Run `helm unittest charts/indi-allsky` → pass; `helm lint` clean; `helm template charts/indi-allsky | kubeconform -strict -ignore-missing-schemas` clean. Commit on `claude/chart-web`, PR, merge.**

---

### Task A7: Edge deployment (indiserver sidecar + daemon, node contract, devices)

**Files:**
- Create: `charts/indi-allsky/templates/edge-deployment.yaml`
- Create: `charts/indi-allsky/tests/edge_test.yaml`

**Interfaces:**
- Consumes: env/overlay (A5), PVC + priorityclass (A4), images (A3).
- Produces: Deployment `<fullname>-edge`; container names `daemon` and (sidecar mode) `indiserver`. e2e (A9) execs into `daemon`.

> **Binding A5 handoff:** the edge pod consumes the application Secret only,
> never the MariaDB root Secret. Before invoking the daemon entrypoint, A7 owns
> a separate bounded wait that reads the fixed applied sentinel from the shared
> parent volume, removes at most one trailing newline, and requires exact
> equality with `INDIALLSKY_CONFIG_OVERLAY_SHA256`. It reports missing, stale,
> empty, and malformed content diagnostically and exits on timeout. After this
> overlay-version gate passes, the daemon entrypoint's existing bounded
> `config.py dumpfile` loop remains the separate database/bootstrap gate.
>
> A matching sentinel does not order an image/schema-only upgrade when the
> canonical overlay is unchanged. A7 must not treat it as a migration epoch;
> issue #9 owns the general migration-order decision and upgrade-path e2e.

- [ ] **Step 1: Failing unit tests**

```yaml
# charts/indi-allsky/tests/edge_test.yaml
suite: edge
templates: [edge-deployment.yaml]
tests:
  - it: pins to camera+sensors labels with priority class
    asserts:
      - equal: { path: spec.template.spec.nodeSelector["indi-allsky.io/camera"], value: "true" }
      - equal: { path: spec.template.spec.nodeSelector["indi-allsky.io/sensors"], value: "true" }
      - equal: { path: spec.template.spec.priorityClassName, value: RELEASE-NAME-indi-allsky-capture }
      - equal: { path: spec.strategy.type, value: Recreate }
  - it: drops sensors label when sensors disabled
    set: { edge.sensors.enabled: false }
    asserts:
      - isNullOrEmpty: { path: spec.template.spec.nodeSelector["indi-allsky.io/sensors"] }
  - it: has indiserver sidecar in sidecar mode, not in external mode
    asserts:
      - equal: { path: spec.template.spec.containers[1].name, value: indiserver }
  - it: external mode drops the sidecar
    set: { indiserver: { mode: external, external: { host: indiserver.example.com, port: 7624 } } }  # [fixture hostname neutralized in review]
    asserts:
      - lengthEqual: { path: spec.template.spec.containers, count: 1 }
  - it: hostpath mode mounts devices privileged
    asserts:
      - equal: { path: spec.template.spec.containers[1].securityContext.privileged, value: true }
      - contains:
          path: spec.template.spec.volumes
          content: { name: cameradev-0, hostPath: { path: /dev/bus/usb } }
  - it: none mode grants no devices and no privilege
    set: { edge.devices.mode: none }
    asserts:
      - isNullOrEmpty: { path: spec.template.spec.containers[0].securityContext }
      - lengthEqual: { path: spec.template.spec.volumes, count: 4 }   # data, etc, varlib, tmp only
  - it: indiserver exposes tcp probes for hang detection
    asserts:
      - equal: { path: spec.template.spec.containers[1].livenessProbe.tcpSocket.port, value: 7624 }
  - it: camera-only hostpath leaves the daemon unprivileged
    set: { edge.sensors.enabled: false }
    asserts:
      - isNullOrEmpty: { path: spec.template.spec.containers[0].securityContext }
      - equal: { path: spec.template.spec.containers[1].securityContext.privileged, value: true }
  - it: device-plugin mode requests extended resources unprivileged
    set:
      edge.devices:
        mode: device-plugin
        camera: { resources: { squat.ai/asi-camera: 1 } }
        sensors: { resources: { squat.ai/i2c: 1 } }
    asserts:
      - isNullOrEmpty: { path: spec.template.spec.containers[1].securityContext }
      - equal: { path: spec.template.spec.containers[1].resources.limits["squat.ai/asi-camera"], value: 1 }
```

- [ ] **Step 2: edge-deployment.yaml**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "indi-allsky.fullname" . }}-edge
  labels: {{- include "indi-allsky.labels" . | nindent 4 }}
spec:
  replicas: 1
  strategy: { type: Recreate }   # the camera is exclusive; never two claimants
  selector:
    matchLabels: {{- include "indi-allsky.componentLabels" (dict "ctx" . "component" "edge") | nindent 6 }}
  template:
    metadata:
      labels: {{- include "indi-allsky.componentLabels" (dict "ctx" . "component" "edge") | nindent 8 }}
      annotations:
        {{- with .Values.edge.podAnnotations }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
        checksum/env: {{ include (print $.Template.BasePath "/configmap-env.yaml") . | sha256sum }}
        # Expected checksum is compared against the fixed applied sentinel on
        # the shared parent volume before capture starts.
        checksum/overlay: {{ include "indi-allsky.overlayChecksum" . }}
    spec:
      {{- with .Values.image.pullSecrets }}
      imagePullSecrets: {{- toYaml . | nindent 8 }}
      {{- end }}
      nodeSelector:
        {{ .Values.nodeContract.cameraLabel }}: "true"
        {{- if .Values.edge.sensors.enabled }}
        {{ .Values.nodeContract.sensorsLabel }}: "true"
        {{- end }}
      {{- with .Values.edge.tolerations }}
      tolerations: {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- if .Values.edge.priorityClass.create }}
      priorityClassName: {{ include "indi-allsky.resourceName" (dict "ctx" . "suffix" "capture" "maxLength" 63) }}
      {{- end }}
      securityContext:
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        {{- if and (eq .Values.edge.devices.mode "hostpath") .Values.edge.supplementalGroups }}
        supplementalGroups: {{ toYaml .Values.edge.supplementalGroups | nindent 10 }}
        {{- end }}
      containers:
        - name: daemon
          image: '{{ include "indi-allsky.image" (dict "ctx" . "name" "daemon") }}'
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          envFrom:
            - configMapRef: { name: {{ include "indi-allsky.envConfigMapName" . }} }
            - secretRef: { name: {{ include "indi-allsky.envSecretName" . }} }
          {{- if and (eq .Values.edge.devices.mode "hostpath") .Values.edge.sensors.enabled }}
          # Privilege scoped per container (security review 2026-08-20): the daemon
          # needs it only for sensor device nodes (i2c/gpio/w1); camera privilege
          # lives on the indiserver container. Camera-only installs get an
          # unprivileged daemon.
          securityContext: { privileged: true }
          {{- end }}
          # No default livenessProbe (architect review 2026-08-20): the daemon is
          # PID 1 via exec, so its death already restarts the container — and the
          # pidfile is unusable as a signal (allsky.py:314 reopens it 'w+' to hold
          # its flock, truncating it; verified empirically). Opt-in freshness probe
          # below restarts on stale latest.jpg; off by default because a threshold
          # under the real cadence (long exposures, disabled day capture, darks
          # mode) false-positives.
          {{- if .Values.edge.freshnessProbe.enabled }}
          livenessProbe:
            exec:
              command: [/bin/bash, -c, '[ -f /var/www/html/allsky/images/latest.jpg ] && test $(( $(date +%s) - $(stat -c %Y /var/www/html/allsky/images/latest.jpg) )) -lt {{ int .Values.edge.freshnessProbe.maxAgeSeconds }}']
            initialDelaySeconds: 300
            periodSeconds: 120
            failureThreshold: 3
          {{- end }}
          resources:
            {{- if eq .Values.edge.devices.mode "device-plugin" }}
            requests: {{- mustMergeOverwrite (deepCopy .Values.edge.resources.requests) .Values.edge.devices.sensors.resources | toYaml | nindent 12 }}
            limits: {{- mustMergeOverwrite (deepCopy .Values.edge.resources.limits) .Values.edge.devices.sensors.resources | toYaml | nindent 12 }}
            {{- else }}
            {{- toYaml .Values.edge.resources | nindent 12 }}
            {{- end }}
          volumeMounts:
            - { name: data, mountPath: /var/www/html }
            - { name: etc, mountPath: /etc/indi-allsky }
            - { name: varlib, mountPath: /var/lib/indi-allsky }
            - { name: tmp, mountPath: /tmp }
            {{- if and (eq .Values.edge.devices.mode "hostpath") .Values.edge.sensors.enabled }}
            {{- range $i, $p := .Values.edge.devices.sensors.hostPaths }}
            - { name: sensordev-{{ $i }}, mountPath: {{ $p }} }
            {{- end }}
            {{- end }}
        {{- if eq .Values.indiserver.mode "sidecar" }}
        - name: indiserver
          image: '{{ include "indi-allsky.image" (dict "ctx" . "name" "indiserver") }}'
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          env:
            - name: INDIALLSKY_INDI_CCD_DRIVER
              value: {{ .Values.indiserver.ccdDriver | quote }}
            {{- with .Values.indiserver.gpsDriver }}
            - name: INDIALLSKY_INDI_GPS_DRIVER
              value: {{ . | quote }}
            {{- end }}
          # Catches a dead/hung indiserver TCP listener cheaply. It does NOT catch
          # a USB-wedged driver whose listener still answers (the ASI reset issue) —
          # the opt-in daemon freshness probe covers that class. Container-scoped
          # indiserver restarts are safe: upstream reconnects and re-registers the
          # camera on disconnect/hotplug (capture.py:394-403) — cite in docs.
          livenessProbe:
            tcpSocket: { port: 7624 }
            initialDelaySeconds: 30
            periodSeconds: 30
            failureThreshold: 4
          readinessProbe:
            tcpSocket: { port: 7624 }
            initialDelaySeconds: 10
            periodSeconds: 10
          {{- if eq .Values.edge.devices.mode "hostpath" }}
          securityContext: { privileged: true }
          {{- end }}
          resources:
            {{- if eq .Values.edge.devices.mode "device-plugin" }}
            requests: {{- mustMergeOverwrite (deepCopy .Values.indiserver.resources.requests) .Values.edge.devices.camera.resources | toYaml | nindent 12 }}
            limits: {{- mustMergeOverwrite (deepCopy .Values.indiserver.resources.limits) .Values.edge.devices.camera.resources | toYaml | nindent 12 }}
            {{- else }}
            {{- toYaml .Values.indiserver.resources | nindent 12 }}
            {{- end }}
          volumeMounts:
            {{- if eq .Values.edge.devices.mode "hostpath" }}
            {{- range $i, $p := .Values.edge.devices.camera.hostPaths }}
            - { name: cameradev-{{ $i }}, mountPath: {{ $p }} }
            {{- end }}
            {{- end }}
        {{- end }}
      volumes:
        - name: data
          persistentVolumeClaim: { claimName: {{ include "indi-allsky.dataPvcName" . }} }
        - name: etc
          emptyDir: { medium: Memory, sizeLimit: 1Mi }
        - name: varlib
          emptyDir: {}   # pidfile + test-camera state; per-pod is correct
        - name: tmp
          emptyDir: {}   # capture -> image worker raw-frame handoff
        {{- if eq .Values.edge.devices.mode "hostpath" }}
        {{- range $i, $p := .Values.edge.devices.camera.hostPaths }}
        - name: cameradev-{{ $i }}
          hostPath: { path: {{ $p }} }
        {{- end }}
        {{- if .Values.edge.sensors.enabled }}
        {{- range $i, $p := .Values.edge.devices.sensors.hostPaths }}
        - name: sensordev-{{ $i }}
          hostPath: { path: {{ $p }} }
        {{- end }}
        {{- end }}
        {{- end }}
```

- [ ] **Step 3: Run `helm unittest charts/indi-allsky`** — assertions are content-based (`contains`/`lengthEqual`), never raw array indexes (SDET review 2026-08-20). Expected: pass. `helm lint` + kubeconform clean.

- [ ] **Step 4: Extend the living docs:** append the device-access modes and host-prep prerequisites (i2c dtparam, `w1-gpio` overlay, udev rules, `supplementalGroups` gid note) to `docs/node-contract.md` and seed `docs/host-prep.md`; A10 finalizes.

- [ ] **Step 5: Commit on `claude/chart-edge`, PR, merge.**

---

### Task A8: Mosquitto (optional), NFD rule, example values

**Files:**
- Create: `charts/indi-allsky/templates/mosquitto-deployment.yaml`, `templates/mosquitto-service.yaml`, `templates/nfd-rule.yaml`
- Create: `examples/values-zwo-pi.yaml`
- Create: `charts/indi-allsky/tests/extras_test.yaml`

**Interfaces:**
- Produces: Service `<fullname>-mosquitto:1883` (plain MQTT; TLS is out of scope v1 — operators bring their own broker for TLS); NodeFeatureRule labeling `indi-allsky.io/camera` from USB vendor IDs.

- [ ] **Step 1: Failing tests** — mosquitto absent by default, present when enabled; NFD rule absent by default, vendor list rendered when enabled:

```yaml
# charts/indi-allsky/tests/extras_test.yaml
suite: extras
templates: [mosquitto-deployment.yaml, mosquitto-service.yaml, nfd-rule.yaml]
tests:
  - it: nothing renders by default
    asserts:
      - hasDocuments: { count: 0 }
  - it: mosquitto renders when enabled
    templates: [mosquitto-deployment.yaml, mosquitto-service.yaml]
    set: { mosquitto.enabled: true }
    asserts:
      - hasDocuments: { count: 2 }
  - it: nfd rule carries the vendor list
    templates: [nfd-rule.yaml]
    set: { discovery.nfd.enabled: true }
    asserts:
      - equal: { path: spec.rules[0].matchFeatures[0].matchExpressions.vendor.op, value: In }
      - contains: { path: spec.rules[0].matchFeatures[0].matchExpressions.vendor.value, content: "03c3" }
```

- [ ] **Step 2: Templates**

```yaml
# templates/mosquitto-deployment.yaml
{{- if .Values.mosquitto.enabled }}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "indi-allsky.fullname" . }}-mosquitto
  labels: {{- include "indi-allsky.labels" . | nindent 4 }}
spec:
  replicas: 1
  selector:
    matchLabels: {{- include "indi-allsky.componentLabels" (dict "ctx" . "component" "mosquitto") | nindent 6 }}
  template:
    metadata:
      labels: {{- include "indi-allsky.componentLabels" (dict "ctx" . "component" "mosquitto") | nindent 8 }}
    spec:
      containers:
        - name: mosquitto
          image: {{ .Values.mosquitto.image }}
          command: [/usr/sbin/mosquitto, -c, /mosquitto-no-auth.conf]
          ports: [{ containerPort: 1883, name: mqtt }]
          {{- with .Values.mosquitto.resources }}
          resources: {{- toYaml . | nindent 12 }}
          {{- end }}
{{- end }}
```

```yaml
# templates/mosquitto-service.yaml
{{- if .Values.mosquitto.enabled }}
apiVersion: v1
kind: Service
metadata:
  name: {{ include "indi-allsky.fullname" . }}-mosquitto
  labels: {{- include "indi-allsky.labels" . | nindent 4 }}
spec:
  ports: [{ port: 1883, targetPort: mqtt, name: mqtt }]
  selector: {{- include "indi-allsky.componentLabels" (dict "ctx" . "component" "mosquitto") | nindent 4 }}
{{- end }}
```

```yaml
# templates/nfd-rule.yaml
{{- if .Values.discovery.nfd.enabled }}
apiVersion: nfd.k8s-sigs.io/v1alpha1
kind: NodeFeatureRule
metadata:
  name: {{ include "indi-allsky.fullname" . }}-camera
  labels: {{- include "indi-allsky.labels" . | nindent 4 }}
spec:
  rules:
    - name: "indi-allsky usb astro camera"
      labels:
        {{ .Values.nodeContract.cameraLabel }}: "true"
      matchFeatures:
        - feature: usb.device
          matchExpressions:
            vendor: { op: In, value: {{ .Values.discovery.nfd.usbVendorIds | toJson }} }
{{- end }}
```

(Docs caveat for A10: NFD's usb feature source only reports devices whose class is in its `deviceClassWhitelist` — operators may need to extend NFD worker config for their camera's USB class.)

- [ ] **Step 3: `examples/values-zwo-pi.yaml`** — a realistic ZWO-on-Raspberry-Pi values file:

```yaml
indiserver:
  ccdDriver: indi_asi_ccd
edge:
  devices:
    mode: hostpath
    camera: { hostPaths: ["/dev/bus/usb"] }
    sensors: { hostPaths: ["/dev/i2c-1", "/dev/gpiochip0", "/sys/bus/w1"] }
web:
  ingress:
    enabled: true
    className: traefik
    host: allsky.example.com
storage:
  data: { storageClassName: nfs-csi, size: 250Gi }
appConfig:
  LOCATION_NAME: "Backyard"
  LOCATION_LATITUDE: 40.0
  LOCATION_LONGITUDE: -75.0
credentials:
  existingSecret: indi-allsky-env
```

- [ ] **Step 4: Seed `docs/topologies.md`** (sidecar vs external indiserver, NFD autodiscovery + deviceClassWhitelist caveat); A10 completes it.

- [ ] **Step 5: unittest pass, lint clean, commit on `claude/chart-extras`, PR, merge.**

---

### Task A9: kind e2e — full simulator pipeline in CI

**Files:**
- Create: `e2e/values-e2e.yaml`, `e2e/verify.sh`, `e2e/kind-config.yaml`
- Modify: `.github/workflows/chart-ci.yml` (add `e2e` job)

**Interfaces:**
- Consumes: everything; images from ghcr `:main` tags. **Prerequisite: the GHCR packages must already be public (A2 Step 9 human step)** — kind pulls anonymously, so a still-private package presents here as `ImagePullBackOff`, not as an obvious A2 omission.
- Produces: the release gate — a chart install that demonstrably captures and processes simulator frames.

- [ ] **Step 1: `e2e/values-e2e.yaml`**

```yaml
image: { tag: main }
edge:
  sensors: { enabled: false }
  devices: { mode: none }
  resources:
    requests: { cpu: 200m, memory: 512Mi }
    limits: { cpu: "2", memory: 2Gi }
web:
  # RWO data volume on multi-node kind: web must co-schedule with edge on the
  # labeled node. The e2e's placement assertion is about EDGE following the node
  # contract; web placement stays unconstrained in real RWX deployments.
  nodeSelector: { indi-allsky.io/camera: "true" }
indiserver:
  ccdDriver: indi_simulator_ccd
storage:
  data:
    accessModes: [ReadWriteOnce]   # single-node kind; RWX not available
    size: 2Gi
credentials:
  flaskSecretKey: e2e-secret-key-not-a-secret
  flaskPasswordKey: dGhpc2lzYW5vdGF0ZXN0a2V5Zm9yZTJlb25seSEhIQ==
  mariadbPassword: e2e-password
appConfig:
  CCD_EXPOSURE_MAX: 1.0
  EXPOSURE_PERIOD: 5.0
  EXPOSURE_PERIOD_DAY: 5.0
```

(`flaskPasswordKey` must be a valid Fernet key: generate a throwaway with `python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"` and paste it — the value above is a placeholder shape; replace it during implementation and note it is intentionally public.)

`e2e/kind-config.yaml` — two nodes so the placement assertion is real (architect review 2026-08-20: an e2e that labels its only node cannot test the node contract):

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
  - role: worker
```

- [ ] **Step 2: `e2e/verify.sh`**

```bash
#!/bin/bash
# Proves the full pipeline: simulator frame captured, processed, cataloged, served.
set -o errexit -o nounset -o pipefail
NS="${NS:-default}"
RELEASE="${RELEASE:-allsky}"

kubectl -n "$NS" rollout status "deploy/${RELEASE}-indi-allsky-web" --timeout=600s
kubectl -n "$NS" rollout status "deploy/${RELEASE}-indi-allsky-edge" --timeout=600s

# Node-contract placement assertion (the chart's headline feature)
EDGE_NODE=$(kubectl -n "$NS" get pod -l app.kubernetes.io/component=edge -o jsonpath='{.items[0].spec.nodeName}')
LABELED_NODE=$(kubectl get nodes -l 'indi-allsky.io/camera=true' -o jsonpath='{.items[0].metadata.name}')
[ "$EDGE_NODE" = "$LABELED_NODE" ] || { echo "FAIL: edge scheduled on $EDGE_NODE, node contract labels $LABELED_NODE"; exit 1; }
echo "PASS: edge pinned to the labeled node ($EDGE_NODE)"

echo "Waiting for a processed frame (image table row)…"
for i in $(seq 60); do
    COUNT=$(kubectl -n "$NS" exec "sts/${RELEASE}-indi-allsky-mariadb" -- \
        mariadb -u indi_allsky -pe2e-password indi_allsky -N -B -e 'SELECT COUNT(*) FROM image;' 2>/dev/null || echo 0)
    [ "${COUNT:-0}" -gt 0 ] && break
    sleep 10
done
[ "${COUNT:-0}" -gt 0 ] || { echo "FAIL: no image rows after 10m"; kubectl -n "$NS" logs "deploy/${RELEASE}-indi-allsky-edge" -c daemon --tail=100; exit 1; }
echo "PASS: $COUNT image row(s)"

kubectl -n "$NS" exec "deploy/${RELEASE}-indi-allsky-edge" -c daemon -- test -f /var/www/html/allsky/images/latest.jpg
echo "PASS: latest.jpg exists"

kubectl -n "$NS" port-forward "svc/${RELEASE}-indi-allsky-web" 18080:8080 &
PF_PID=$!; trap 'kill $PF_PID' EXIT
sleep 3
curl -fs "http://127.0.0.1:18080/indi-allsky/js/latest?camera_id=-1&limit_s=86400" | jq -e '.latest_image.url != null'
echo "PASS: web serves the latest image"
```

- [ ] **Step 3: Add the e2e job to chart-ci.yml**

```yaml
  e2e:
    runs-on: ubuntu-24.04
    needs: lint
    steps:
      - uses: actions/checkout@v4
      - uses: azure/setup-helm@<pin-to-commit-SHA>
      - uses: helm/kind-action@<pin-to-commit-SHA>
        with: { config: e2e/kind-config.yaml }
      - name: Label ONLY the worker node with the camera contract
        run: kubectl label node "$(kubectl get nodes -o name | grep -- '-worker$' | head -1 | sed 's|node/||')" indi-allsky.io/camera=true
      - name: Install
        run: helm install allsky charts/indi-allsky -f e2e/values-e2e.yaml --wait --timeout 15m
      - name: Verify pipeline
        run: bash e2e/verify.sh
      - if: failure()
        run: |
          kubectl get pods -A -o wide
          kubectl describe pods
          kubectl logs deploy/allsky-indi-allsky-edge -c daemon --tail=200 || true
          kubectl logs deploy/allsky-indi-allsky-web -c gunicorn --tail=200 || true
```

- [ ] **Step 4: Run it on a PR branch; iterate until green.** This is the step where integration reality bites (probe timings, image folder perms, first-boot ordering). Debug via the failure-dump step; reproduce locally with `kind create cluster && helm install …` when needed. Expected final state: e2e job green on the PR.

- [ ] **Step 5: Commit fixes, merge.** Evidence: chart-ci `lint` + `e2e` both green on main.

---

### Task A10: Chart release workflow, README, docs

**Files:**
- Create: `.github/workflows/release.yml`
- Create: `docs/node-contract.md`, `docs/host-prep.md`, `docs/topologies.md`
- Create: `examples/argocd-application.yaml`, `examples/flux-helmrelease.yaml`
- Modify: `README.md` (full)

**Interfaces:**
- Produces: OCI chart at `oci://ghcr.io/jaxzin/charts/indi-allsky`, versioned by git tag `chart-v<semver>`; the README node-contract section is the public demarcation doc the spec promised.

- [ ] **Step 1: release.yml**

```yaml
name: release
on:
  push:
    tags: ["chart-v*"]
permissions:
  contents: write
  packages: write
jobs:
  release:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
      - uses: azure/setup-helm@<pin-to-commit-SHA>
      - name: Push chart
        run: |
          VERSION="${GITHUB_REF_NAME#chart-v}"
          helm registry login ghcr.io -u "$GITHUB_ACTOR" -p "${{ secrets.GITHUB_TOKEN }}"
          helm package charts/indi-allsky --version "$VERSION"
          helm push "indi-allsky-${VERSION}.tgz" oci://ghcr.io/jaxzin/charts
      - uses: softprops/action-gh-release@<pin-to-commit-SHA>
        with: { generate_release_notes: true }
```

- [ ] **Step 2: docs/node-contract.md** — the demarcation contract, verbatim themes from the spec: the two labels and what each promises; camera+sensors same-node constraint and why (upstream shared-memory process model); autodiscovery (NFD rule, vendor IDs, deviceClassWhitelist caveat) vs manual labeling; scheduling postures (share-with-protection via PriorityClass+Guaranteed QoS as default posture; dedicated-taint as the alternative with example taint + toleration values); what the chart never does (host config). Security limitations stated plainly (2026-08-21): nginx serves the image archive unauthenticated regardless of `web.authAllViews` (the alias bypasses Flask's media auth — an operator wanting a private archive must gate at the ingress), and digest pinning is the production path (tag drift note already in the release guidance).

- [ ] **Step 3: docs/host-prep.md** — prerequisites the chart expects the node OS to provide: i2c enabled (`dtparam=i2c_arm=on`), `w1-gpio` dtoverlay for DS18x20, camera vendor udev rules, NFS client (`nfs-common`) on any node mounting an NFS-backed data PVC, group-ID note for `supplementalGroups`. docs/topologies.md — v1 topology diagram, the `indiserver.mode: external` escape hatch (libcamera/host-indiserver users), phase-2 `videoWorker.mode: cluster` (planned), full-split ceiling (documented, unbuilt), syncapi recipe (future).

- [ ] **Step 4: examples/argocd-application.yaml + flux-helmrelease.yaml**

```yaml
# examples/argocd-application.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: indi-allsky
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/jaxzin/indi-allsky-helm
    targetRevision: chart-v0.1.0
    path: charts/indi-allsky
    helm:
      valueFiles: [../../examples/values-zwo-pi.yaml]
  destination:
    server: https://kubernetes.default.svc
    namespace: indi-allsky
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true]
```

```yaml
# examples/flux-helmrelease.yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata: { name: indi-allsky, namespace: flux-system }
spec:
  type: oci
  url: oci://ghcr.io/jaxzin/charts
  interval: 1h
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata: { name: indi-allsky, namespace: indi-allsky }
spec:
  chart:
    spec:
      chart: indi-allsky
      version: "0.1.x"
      sourceRef: { kind: HelmRepository, name: indi-allsky, namespace: flux-system }
  interval: 1h
  values: {}   # see examples/values-zwo-pi.yaml
```

- [ ] **Step 5: README.md** — what it is, quickstart (`helm install` from OCI), values highlights table, link to docs/, upstream relationship + license note, project status (v1: edge topology; roadmap: video-worker extraction with upstream PR).

- [ ] **Step 6: Verify the v2 migration-hardening issue exists and link it from the README roadmap.** The TPM files it (ownership decision 2026-08-20 — tracker work belongs to the TPM; this step only verifies, preventing double-filing). Required content, whoever ends up filing: title "Commit alembic revisions in CI; runtime becomes upgrade-only; add upgrade-path e2e"; rationale (unattended runtime autogenerate is upstream's pattern, guarded v1 by pre-migrate dumps; reproducible schema requires revisions in the image); acceptance criteria (CI job generates revisions against MariaDB at the pinned ref and commits them; `migrate.sh` drops autogenerate; e2e installs vN, seeds rows, upgrades to vN+1, asserts row survival); and the hard gate: **no `UPSTREAM_VERSION` bump PR merges before this closes**.

- [ ] **Step 7: Tag `chart-v0.1.0`, verify release workflow green, `helm pull oci://ghcr.io/jaxzin/charts/indi-allsky --version 0.1.0` succeeds.** Record in the release notes: the tag's commit SHA AND the three image digests (`docker buildx imagetools inspect` each image at its upstream tag) — consumers use them for `image.digests.*` pinning, and the notes state plainly that digest pinning is the intended production path (with digests unset and `pullPolicy: IfNotPresent`, cached vs fresh nodes can silently run different manifests under one tag). Two consumption channels, one per consumer: public operators use the OCI chart (`helm install oci://…`); the operator's private deployment plan consumes the git path `charts/indi-allsky` pinned to that release commit SHA with digest-pinned images.
