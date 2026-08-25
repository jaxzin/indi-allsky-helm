# indi-allsky-helm

A Helm chart and multi-arch container images for running
[indi-allsky](https://github.com/aaronwmorris/indi-allsky) by Aaron Morris on
any home Kubernetes cluster. All the interesting astronomy happens upstream —
this repo only packages it for Kubernetes.

## Status

Images first, chart under construction. The container image build pipeline is
in place; the Helm chart is not yet published or installable. Watch the
releases for the first chart version.

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
  `default`. Current targets: `base` (untagged intermediate) and
  `indiserver`; the daemon and web images are added next.
- CI builds each architecture natively (`linux/amd64` on `ubuntu-24.04`,
  `linux/arm64` on `ubuntu-24.04-arm` — no QEMU for the INDI compile),
  pushes by digest, then merges the per-arch digests into multi-arch
  manifest lists.
- Published images: `ghcr.io/jaxzin/indi-allsky-indiserver` (daemon and web
  variants to follow), each tagged `main` and with the contents of
  `UPSTREAM_VERSION`; platforms `linux/amd64,linux/arm64`.
- CI keeps its registry build cache in the `ghcr.io/jaxzin/indi-allsky-cache`
  GHCR package (one tag per target and architecture); only authenticated CI
  reads or writes it, so it stays private.
