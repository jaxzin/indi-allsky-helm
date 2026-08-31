# "daemon.upstream" is a buildx named context supplied by images/docker-bake.hcl
# (contexts = { "daemon.upstream" = "target:daemon-upstream" }), not a registry
# reference — it has no tag to pin.
# hadolint ignore=DL3006
FROM daemon.upstream

USER 0

# Removing the sudoers policy makes sudo fail closed but leaves /usr/bin/sudo
# setuid-root, still exposed to the sudo CVE class. Purge the package too.
# SUDO_FORCE_REMOVE is required: Debian's sudo.prerm refuses removal while the
# root account is locked — which it always is in a container image. Nothing in
# this repo's entrypoints or upstream's Python calls sudo (only upstream's
# start scripts did, and this image replaces them).
#
# Upstream's start script goes with it. This image supplies the ENTRYPOINT
# instead, and that script opens with `sudo chown` — so it is not merely
# unused, it is guaranteed-broken dead weight whose only remaining effect
# would be to mislead anyone who overrode the entrypoint to run it.
#
# build_indi.sh and build_libcamera.sh come from the shared `base` layer and go
# for the same reason: they are build-time scripts that call sudo, so in this
# image — and only this image, since indiserver keeps sudo — they can no longer
# do anything but fail. Removing them here rather than in `base` keeps the
# expensive INDI layer shared with indiserver intact.
RUN rm -f /etc/sudoers /etc/sudoers.d/* \
         /home/allsky/start_indi_allsky.sh \
         /home/allsky/build_indi.sh /home/allsky/build_libcamera.sh \
    && SUDO_FORCE_REMOVE=yes apt-get purge -y sudo \
    && apt-get autoremove -y --purge \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# validators.sh is sourced, never executed, so it is not marked executable.
COPY --chown=10001:10001 --chmod=644 shared/validators.sh /home/allsky/
COPY --chown=10001:10001 --chmod=755 \
    shared/render-flask-config.sh daemon/entrypoint-daemon.sh daemon/wait-overlay.sh \
    /home/allsky/

# Numeric USER: kubelet cannot verify runAsNonRoot against a named user
# ("container has runAsNonRoot and image has non-numeric user").
USER 10001:10001
WORKDIR /home/allsky
ENTRYPOINT ["/home/allsky/entrypoint-daemon.sh"]
