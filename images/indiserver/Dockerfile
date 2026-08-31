# "indiserver.upstream" is a buildx named context supplied by
# images/docker-bake.hcl (contexts = { "indiserver.upstream" =
# "target:indiserver-upstream" }), not a registry reference — it has no tag to
# pin.
# hadolint ignore=DL3006
FROM indiserver.upstream

USER 0

# Removing the sudoers policy makes sudo fail closed but leaves /usr/bin/sudo
# setuid-root, still exposed to the sudo CVE class. Purge the package too.
# SUDO_FORCE_REMOVE is required: Debian's sudo.prerm refuses removal while the
# root account is locked — which it always is in a container image.
#
# This is the container the chart may run privileged (sidecar + local hostPath
# camera), so inherited passwordless sudo is the one privilege-escalation path
# that mattered most here. Nothing in the runtime path calls sudo:
# upstream's start_indiserver.sh execs indiserver directly.
#
# build_indi.sh goes with it. It is a build-time script whose cleanup step runs
# `sudo apt-get clean`, so with sudo purged it can no longer do anything but
# fail — the same reasoning images/daemon/Dockerfile applies to its own copy.
# It is removed here rather than in the shared `base` layer so the expensive
# INDI compile stays cached across both images.
RUN rm -f /etc/sudoers /etc/sudoers.d/* /home/allsky/build_indi.sh \
    && SUDO_FORCE_REMOVE=yes apt-get purge -y sudo \
    && apt-get autoremove -y --purge \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Numeric USER: kubelet cannot verify runAsNonRoot against a named user
# ("container has runAsNonRoot and image has non-numeric user"). Upstream's
# `USER allsky` is the same uid/gid — this restates it in the form the
# restricted (simulator / device-plugin) modes need.
USER 10001:10001
WORKDIR /home/allsky

# Restated verbatim from upstream's Dockerfile.indiserver_debian13 rather than
# inherited, so a future upstream entrypoint change is a visible conflict here
# instead of a silent behaviour change in a privileged container.
ENTRYPOINT ["./start_indiserver.sh"]
