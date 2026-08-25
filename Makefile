UPSTREAM_REF := $(shell cat UPSTREAM_VERSION)
UPSTREAM_REPO := https://github.com/aaronwmorris/indi-allsky.git

.PHONY: upstream bake-print lint

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

lint:
	hadolint images/*/Dockerfile || true  # becomes strict in A3 when Dockerfiles exist
	shellcheck images/*/*.sh 2>/dev/null || true
	actionlint
