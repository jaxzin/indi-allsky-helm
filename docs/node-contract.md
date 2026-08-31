# Node contract

How this chart decides where capture runs, and what it asks of your nodes.

indi-allsky has one hard physical dependency: the node the camera (and any
sensors) are plugged into. The chart expresses that dependency through two
node labels. Everything else — web UI, database, optional MQTT broker —
floats on ordinary cluster compute.

## The two labels

### `indi-allsky.io/camera: "true"`

Promises that this node has the all-sky camera attached. The label is desired
node state, so it belongs to whatever configures your nodes rather than to a
one-off command; the equivalent it has to produce is:

```sh
kubectl label node cam01.example.com indi-allsky.io/camera=true
```

Optionally, [Node Feature Discovery](https://github.com/kubernetes-sigs/node-feature-discovery)
can autodiscover USB astro cameras and apply the label for you — see the
`discovery.nfd.*` values and [topologies.md](topologies.md). NFD has to be
installed already; the chart renders the `NodeFeatureRule`, not NFD itself.

No NFD *worker* configuration is needed. An earlier draft of this page warned
that `sources.usb.deviceClassWhitelist` would hide cameras outside its default
classes; that is true only of NFD's own built-in `usb-*.present` labels. A
`NodeFeatureRule` matches the raw `usb.device` feature set, which nfd-worker
discovers from every `/sys/bus/usb/devices` entry regardless of class.

### `indi-allsky.io/sensors: "true"`

Promises that this node is wired to environmental sensor hardware over GPIO,
i2c, SPI, or 1-wire. There is **no autodiscovery** for it — physical wiring is
invisible to software — so your node configuration always states it explicitly:

```sh
kubectl label node cam01.example.com indi-allsky.io/sensors=true
```

## v1 constraint: camera and sensors on the same node

Upstream indi-allsky runs capture, sensor polling, and image processing as a
single multiprocess application whose processes coordinate over shared
memory — they cannot be split across machines. The chart therefore schedules
capture and sensing together in one edge pod: its node selector requires the
camera label, plus the sensors label when `edge.sensors.enabled` is `true`.
If your sensors are wired to a different machine than your camera, v1 of
this chart cannot express that split.

## Values that express the contract

| Key | Default | Effect |
| --- | --- | --- |
| `nodeContract.cameraLabel` | `indi-allsky.io/camera` | Label key the edge pod always requires on its node |
| `nodeContract.sensorsLabel` | `indi-allsky.io/sensors` | Label key additionally required when sensors are enabled |
| `edge.sensors.enabled` | `false` | Adds the sensors label to the node selector and mounts sensor devices, in hostPath mode |
| `edge.devices.mode` | `none` | `none` (simulator, schedules anywhere), `device-plugin` (extended resource, no label), `hostpath` (explicit opt-in, uses the labels) |

**Neither label is required by default.** With `edge.devices.mode: none` the
edge pod runs the INDI simulator and schedules anywhere. A label requirement
appears only where it is real: the camera label when a local hostPath camera is
configured, and the sensors label when hostPath sensors are enabled. Sensor
placement is independent of the camera.

## Security posture

The chart is hardened by default: every container runs under a restricted
security context (uid/gid 10001, `runAsNonRoot`, no privilege escalation, all
capabilities dropped, `RuntimeDefault` seccomp), and no pod mounts a
service-account token.

**Exactly one container can become privileged, and only on request.** It is
`indiserver`, and only when `edge.devices.mode: hostpath` supplies a local
camera. INDI's USB drivers rebind and reconfigure the device node directly, and
no capability set short of privileged reliably covers that across the vendor
drivers upstream ships — which is why `device-plugin` is the preferred hardware
path and gets the restricted context instead.

Privileged is **not** root here: the pod's `runAsUser: 10001` stays in place.

**Know exactly what that means for device access.** `privileged: true` on a
non-root uid grants *no capabilities* — the effective set is empty, because the
ambient set is empty and the binary carries no file capabilities; only the
bounding set is full. Measured on this image:

| Posture | Effective capabilities | Opens a `root:<group> 0640` node |
| --- | --- | --- |
| privileged, uid 10001, no supplemental group | none | **no** |
| privileged, uid 10001, matching `supplementalGroups` | none | yes |
| privileged, uid 0 | all | yes |

So privileged does **not** bypass the device node's ownership. What it does
provide is an unrestricted device cgroup, a read-write `/sys`, and an
unconfined seccomp/AppArmor profile.

**The operator requirement that follows:** a hostPath camera or sensor node must
be reachable by uid 10001 — either world-readable/writable, or owned by a group
listed in `edge.supplementalGroups`. That is normally what the camera vendor's
udev rule already does (ZWO and QHY both ship rules that set a mode or a group);
if no such rule is installed, the node is typically `root:root 0664` and the
container will get `EACCES` where upstream's root-in-container would not have.
Install the vendor udev rule, or set `edge.supplementalGroups` to the gid the
node actually carries.

Whether this chart should instead run this single container as root is an open
design question, tracked in
[issue #34](https://github.com/jaxzin/indi-allsky-helm/issues/34).

**The daemon is never privileged**, in any mode, including hostPath sensors. It
is an ordinary Python process; the camera is attached to the sidecar, and sensor
device nodes are reached through `edge.supplementalGroups`. The Global
Constraint's exemption for device-attached containers does not extend to the
daemon by adjacency, and this sentence is the written record of that decision.

## Host preparation

Node state is an **input** to this chart, owned by whatever configures your
nodes — Ansible, Terraform/OpenTofu, a machine image, or your cluster's own
bootstrap. The chart never mutates a node.

What `edge.devices.mode: hostpath` assumes you have already arranged:

- the device nodes exist and are readable by a group you list in
  `edge.supplementalGroups` (`dialout`, `gpio`, `i2c` on Raspberry Pi OS and
  Debian defaults — the numeric ids differ per distribution, which is why the
  chart ships none);
- i2c and SPI are enabled and the 1-wire overlay is loaded, if you use those
  sensors;
- udev rules give the camera a stable device node, if your camera needs one;
- the node carries `nodeContract.cameraLabel` and/or `nodeContract.sensorsLabel`.

`edge.devices.mode: device-plugin` replaces most of that with a device plugin
you install separately; the chart then only requests the extended resource the
plugin advertises.

## Topology examples

**Shared node.** Leave `edge.priorityClass.mode: create`. Capture outranks
ordinary workloads on the node it lands on and can preempt them under pressure.
Set `preemptionPolicy: Never` if you would rather capture queued than something
else evicted.

**Dedicated node.** Taint it — for example
`example.com/dedicated=allsky:NoSchedule` — and give the edge pod a matching
`edge.tolerations` entry. Priority then matters less, and
`edge.priorityClass.mode: disabled` is a reasonable choice.

**Several releases, one cluster.** A PriorityClass is cluster-scoped. Have your
platform automation own one class and set `edge.priorityClass.mode: reference`
with its `name` in every release, so the classes cannot fight over one object.
