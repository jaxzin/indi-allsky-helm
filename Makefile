UPSTREAM_REF := $(shell cat UPSTREAM_VERSION)
UPSTREAM_REPO := https://github.com/aaronwmorris/indi-allsky.git

.PHONY: upstream bake-print lint image-contract

upstream:
	@test -f UPSTREAM_SHA || { echo "UPSTREAM_SHA file missing — see README (Re-pinning)"; exit 1; }
	rm -rf upstream
	git clone --depth 1 --branch $(UPSTREAM_REF) $(UPSTREAM_REPO) upstream
	@expected="$$(cat UPSTREAM_SHA)"; actual="$$(git -C upstream rev-parse HEAD)"; \
	if [ "$$actual" != "$$expected" ]; then \
		echo "UPSTREAM_SHA mismatch — tag moved or MITM; refusing to build"; \
		echo "  expected: $$expected"; \
		echo "  actual:   $$actual"; \
		echo "If this re-pin is intentional, follow the Re-pinning section in README.md."; \
		exit 1; \
	fi
	@set -e; for p in patches/*.patch; do [ -e "$$p" ] || continue; echo "Applying $$p"; git -C upstream apply ../$$p; done

bake-print: upstream
	docker buildx bake -f images/docker-bake.hcl --print

# Static image and build-graph contract. Needs the pinned upstream checkout
# because the bake graph references it, but builds and pulls nothing. The
# runtime modes are documented in the script itself.
image-contract: upstream
	images/tests/image-contract.sh --static-contract

# Strict: a lint failure fails the target. The `ls -1` lines print what is
# about to be linted, so a glob that silently matched nothing is visible in the
# output — and, because `ls` fails on a non-matching glob, also fatal.
# hadolint runs from the same pinned image digest CI uses, so a clean local run
# means a clean CI run; that is why this target needs docker.
lint:
	@echo "hadolint:"; ls -1 images/*/Dockerfile
	docker run --rm -v "$$(pwd):/w" -w /w ghcr.io/hadolint/hadolint:v2.15.1-debian@sha256:9a3944b7fddcb947d1ffd90829ac1a6e5c30479223358f249d8b96c7d0019e27 hadolint images/*/Dockerfile
	@echo "shellcheck:"; ls -1 images/*/*.sh
	shellcheck images/*/*.sh
	@echo "chart test shellcheck:"; ls -1 charts/indi-allsky/tests/*.sh
	shellcheck charts/indi-allsky/tests/*.sh
	@echo "e2e shellcheck:"; ls -1 e2e/*.sh
	shellcheck e2e/*.sh
	@echo "scripts shellcheck:"; ls -1 scripts/*.sh
	shellcheck scripts/*.sh
	actionlint
