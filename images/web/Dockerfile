# "web.upstream" is a buildx named context supplied by images/docker-bake.hcl
# (contexts = { "web.upstream" = "target:web-upstream" }), not a registry
# reference — it has no tag to pin.
# hadolint ignore=DL3006
FROM web.upstream

USER 0

# mariadb-client supplies mariadb-dump, which migrate.sh uses for the
# pre-migration backup, and the mariadb client used by the bench tests.
#
# Removing the sudoers policy makes sudo fail closed but leaves /usr/bin/sudo
# setuid-root, still exposed to the sudo CVE class. Purge the package too.
# SUDO_FORCE_REMOVE is required: Debian's sudo.prerm refuses removal while the
# root account is locked — which it always is in a container image. Nothing in
# this repo's entrypoints or upstream's Python calls sudo (only upstream's
# start scripts did, and this image replaces them).
#
# Exact apt version pins on a floating Debian base (python:3.13-slim tracks
# Debian point releases) are false precision: they break on every point release
# while the base itself keeps floating. The upstream pin that actually governs
# reproducibility is UPSTREAM_SHA.
# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get install -y --no-install-recommends mariadb-client \
    && rm -f /etc/sudoers /etc/sudoers.d/* \
    && SUDO_FORCE_REMOVE=yes apt-get purge -y sudo \
    && apt-get autoremove -y --purge \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# migrate.sh's guard depends on `flask db check`. Upstream's floor (>=4.0.5)
# already provides it; this restates the dependency explicitly so a future
# upstream floor change cannot silently remove the guard. No-op when the
# resolved version already satisfies it.
RUN /home/allsky/venv/bin/pip install --no-cache-dir 'Flask-Migrate>=4.0.6'

COPY --chown=10001:10001 --chmod=755 \
    shared/render-flask-config.sh web/entrypoint-web.sh web/migrate.sh \
    /home/allsky/

# Numeric USER: kubelet cannot verify runAsNonRoot against a named user
# ("container has runAsNonRoot and image has non-numeric user").
USER 10001:10001
WORKDIR /home/allsky
EXPOSE 8000
ENTRYPOINT ["/home/allsky/entrypoint-web.sh"]
