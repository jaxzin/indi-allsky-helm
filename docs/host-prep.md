# Host preparation

What the node OS has to provide before this chart can use the hardware plugged
into it. **The chart never configures a node.** Node state is an input, owned
by whatever configures your machines — Ansible, a machine image, your cluster's
own bootstrap — and none of the steps below are things Helm can do for you.

Skip this page entirely if you are running `edge.devices.mode: none` — the
default INDI simulator touches no host hardware at all. With
`indiserver.mode: external` the camera section does not apply either, since the
camera belongs to a server this chart does not manage; the sensor and storage
sections still do.

The commands here are Raspberry Pi OS / Debian, because that is what an all-sky
camera is usually plugged into. Translate as needed; the *requirements* are the
portable part.

## The one rule that explains the rest

Containers in this chart run as **uid 10001**, and `privileged: true` does not
change that. A privileged container running as a non-root uid gets an *empty*
effective capability set — no `CAP_DAC_OVERRIDE`, so it does not bypass file
permissions. It gets an unrestricted device cgroup, a read-write `/sys`, and an
unconfined seccomp profile, and that is all.

Measured, not assumed — see the capability table in
[node-contract.md](node-contract.md#security-posture).

**Therefore every device node the pod opens must be reachable by uid 10001**,
either world-accessible or owned by a group listed in
`edge.supplementalGroups`. Upstream's bare-metal install runs as a real user in
the right groups and its container path runs as root, so neither hits this;
this chart does. Almost every "works on bare metal, `EACCES` in the pod" report
is this one rule.

Read the group ids off the node itself — they differ between distributions and
releases, which is why the chart ships none:

```sh
getent group dialout gpio i2c spi | cut -d: -f1,3
```

Then put the numeric ids in your values:

```yaml
edge:
  supplementalGroups: [20, 993, 994]
```

## Camera

The camera vendor's udev rule is what gives the USB device node a group — or a
permissive mode — that a non-root process can open. Without one the node is
typically `root:root 0664`, and capture fails with `EACCES` no matter what else
is configured.

Those rules ship with the vendor libraries: `libasi` for ZWO, `libqhy` for QHY,
both from the INDI repositories, and both installed by upstream's own `setup.sh`
on a bare-metal host. Install the vendor package on the node, or drop its rule
file into `/etc/udev/rules.d/` yourself.

**Installing it in the container does nothing.** udev runs on the node and
creates the device nodes there; the container only sees the result through the
hostPath mount. A rule that exists only inside the image never runs.

Reload without a reboot:

```sh
sudo udevadm control --reload-rules && sudo udevadm trigger
```

Then confirm what the node actually shows, and that its group is one you listed:

```sh
ls -l /dev/bus/usb/*/*
```

Mount `/dev/bus/usb` as a directory rather than a fixed device node: libusb
rebinds the camera on reconnect and the numbered node moves with it. See
[examples/values-zwo-pi.yaml](../examples/values-zwo-pi.yaml).

**USB replug generally needs an edge-pod restart.** The pod's mount is a
snapshot of the bus directory at start; a camera that disappears and comes back
does not reliably reappear inside the running container.

## Sensors

### i2c

Enable the bus in `/boot/firmware/config.txt` (older images: `/boot/config.txt`)
and reboot:

```
dtparam=i2c_arm=on
```

Verify `/dev/i2c-1` exists and note its group:

```sh
ls -l /dev/i2c-1
```

### 1-wire (DS18B20 and friends)

Load the overlay in the same file, and reboot:

```
dtoverlay=w1-gpio
```

Verify the sysfs tree appears, with at least one `28-*` device for a DS18x20:

```sh
ls /sys/bus/w1/devices/
```

Mount `/sys/bus/w1` with `readOnly: true` — a probe is only ever read, and the
chart renders exactly the access you state.

### GPIO (dew heater, fan)

`/dev/gpiochip0` exists by default on Raspberry Pi OS. It is normally owned by
the `gpio` group; include that gid in `edge.supplementalGroups`.

### SPI

If your sensor is on SPI, add `dtparam=spi=on` and mount the matching
`/dev/spidev*` node.

All of these go in `edge.devices.sensors.hostPaths` with an explicit `type` and
`readOnly` — the chart renders what you state and never infers access from a
path. `edge.sensors.enabled: true` additionally pins the pod to a node carrying
`nodeContract.sensorsLabel`.

## Node labels

The chart selects on labels; it never applies them.

```sh
kubectl label node cam01.example.com indi-allsky.io/camera=true
kubectl label node cam01.example.com indi-allsky.io/sensors=true
```

These are desired node state, so they belong in whatever configures your
cluster rather than in a one-off command. USB cameras can be labelled
automatically instead — see the NFD section of
[topologies.md](topologies.md#camera-autodiscovery-with-nfd). Sensor wiring
cannot: it is invisible to software.

Camera and sensors must be on the **same** node in v1. See
[node-contract.md](node-contract.md#v1-constraint-camera-and-sensors-on-the-same-node).

## NFS-backed storage

The chart's shared data volume defaults to `ReadWriteMany`, because the edge
pod is pinned to the camera node while the web pod floats. NFS is the usual way
to get RWX in a homelab.

**Every node that could mount that PVC needs an NFS client installed** — the
in-tree and CSI NFS drivers both call the kernel mount helper, which is not
present by default on a minimal image:

```sh
sudo apt-get install -y nfs-common
```

That includes the camera node, the nodes the web pod might land on, and
whichever node runs the backup CronJob. A missing `nfs-common` shows up as a
pod stuck in `ContainerCreating` with a `mount.nfs: ... helper program not
found` event, on that node only — so it can look like an intermittent
scheduling problem rather than a missing package.

The share's own export options are the storage system's concern, but one of
them matters here: the export has to let **uid 10001** write. `root_squash` is
irrelevant, because nothing in this chart writes as root — but an export that
squashes all users, or whose uid mapping has no 10001, will fail writes that
look like a permissions bug in the application.

## Container runtime

Nothing special is required. The chart does not need a particular runtime,
cgroup version, or seccomp configuration, and it never asks for a host
namespace. It needs no `hostNetwork`, no `hostPID`, and no writable host paths
outside the device nodes you list.

## What the chart does instead of host config

| Concern | Owned by |
| --- | --- |
| udev rules, dtoverlays, kernel modules, packages | your node configuration |
| node labels and taints | your node configuration |
| which node capture lands on | the chart, via `nodeContract.*` labels |
| which device paths are mounted | the chart, from `edge.devices.*.hostPaths` |
| which gids the pod carries | the chart, from `edge.supplementalGroups` |

If you would rather not do any of this, `edge.devices.mode: device-plugin`
moves device access to a device plugin you install separately: the chart then
requests only the extended resource the plugin advertises, and the edge pod
stays unprivileged. It is the preferred hardware path.

## Related

- [node-contract.md](node-contract.md) — the labels, the scheduling postures,
  and the measured privilege/capability behaviour.
- [topologies.md](topologies.md) — sidecar vs external indiserver, NFD
  autodiscovery, the optional broker.
- [configuration.md](configuration.md) — every value, and the lifecycle
  contracts to read before production.
