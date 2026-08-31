# Topologies

Where the pieces run, and the choices that decide it.

## v1: capture is pinned, everything else floats

One shape ships today. The edge pod is pinned to the node the hardware is
plugged into; the web UI, the database and the optional broker are ordinary
cluster workloads that land wherever the scheduler puts them.

```
  camera node (indi-allsky.io/camera)      anywhere in the cluster
  ┌──────────────────────────────────┐     ┌─────────────────────────────┐
  │ edge pod        pinned by label  │     │ web pod              floats │
  │                                  │     │                             │
  │  indiserver ──▶ camera device    │     │  nginx :8080  ──▶ gunicorn  │
  │      ▲                           │     │  (the Service target)       │
  │      │ :7624, pod loopback       │     │                             │
  │  daemon ──▶ i2c / gpio / 1-wire  │     │                             │
  └──────────────┬───────────────────┘     └───────────────┬─────────────┘
                 │                                         │
      read-write │      ┌────────────────────────┐         │ read-only
                 ├─────▶│ shared data PVC  (RWX) │◀────────┤
                 │      │  allsky/  images       │         │
                 │      │  .state/  dumps, tree  │         │
                 │      └────────────────────────┘         │
                 │      ┌────────────────────────┐         │
                 └─────▶│ mariadb :3306          │◀────────┘
                        │  or externalDatabase.* │
                        └────────────────────────┘
```

The optional mosquitto broker sits alongside on `:1883`, reachable from the
edge pod and nothing else.

Two things follow from that picture, and both bite in practice:

- **The data volume defaults to `ReadWriteMany`.** Edge writes it, web reads
  it, and they are not on the same node. A `ReadWriteOnce` volume forces the
  web pod onto the camera node — legal, but then it is no longer floating.
- **Web-to-daemon commands take up to 13 seconds.** Upstream polls the database
  for them rather than calling the daemon; that is upstream's design, not a
  chart delay.

Why the edge pod is one pod rather than several is upstream's process model,
not a packaging choice — see
[node-contract.md](node-contract.md#v1-constraint-camera-and-sensors-on-the-same-node).

## Where indiserver runs

`indiserver.mode` picks between two shapes.

### `sidecar` (default)

indiserver runs as a container in the edge pod, and the daemon reaches it over
the pod's own loopback on `:7624`. The camera is attached to this node.

```
        edge pod
  ┌───────────────────────┐
  │ daemon ──▶ indiserver │──▶ /dev/bus/usb on this node
  └───────────────────────┘
```

Use this when the camera is plugged into a machine in your cluster. It is the
only mode in which the chart mounts host devices, and the only one in which any
container becomes privileged — see [node-contract.md](node-contract.md).

### `external`

indiserver runs somewhere this chart does not manage — a bare-metal box, a
different cluster, an appliance — and the daemon connects to
`indiserver.external.host:port` over the network.

```
  edge pod                          elsewhere
  ┌──────────┐                  ┌─────────────┐
  │  daemon  │─── TCP :7624 ───▶│ indiserver  │──▶ camera
  └──────────┘                  └─────────────┘
```

Use this when the camera cannot be attached to a cluster node, or when you
already run indiserver and want the chart to consume it. In this mode the edge
pod carries no host devices, no privileged container, and no node label
requirement for the camera — `edge.devices.camera.*` must be empty, because the
camera belongs to the external server rather than to this pod.

The chart renders no egress NetworkPolicy, so nothing blocks the daemon from
reaching an external indiserver.

## Camera autodiscovery with NFD

Set `discovery.nfd.enabled: true` and the chart renders a `NodeFeatureRule`
that labels any node with a matching USB vendor id:

```yaml
discovery:
  nfd:
    enabled: true
    usbVendorIds: ["03c3"]   # ZWO. "1618" is QHY.
```

The label it applies is `nodeContract.cameraLabel` (`indi-allsky.io/camera` by
default), which is exactly what `edge.devices.mode: hostpath` selects on. So
with NFD in the cluster, plugging the camera into a different node moves
capture to that node without anyone editing a label.

**Requirements and sharp edges:**

- **NFD must already be installed.** The chart renders the custom resource, not
  the CRD or the controller. `NodeFeatureRule` is `nfd.k8s-sigs.io/v1alpha1`;
  install NFD first, or the resource is rejected as an unknown kind.
- **Quote the vendor ids.** `1618` unquoted is a YAML integer, and the CRD types
  these as strings. Four lowercase hex digits, matching what the kernel reports
  in sysfs `idVendor`. The chart rejects anything else at render time rather
  than letting you apply a rule that silently never matches.
- **`deviceClassWhitelist` does not apply here.** NFD's
  `sources.usb.deviceClassWhitelist` (default `["0e", "ef", "fe", "ff"]`)
  governs only NFD's *own* built-in
  `feature.node.kubernetes.io/usb-<class>_<vendor>_<device>.present` labels. A
  `NodeFeatureRule` matches the raw `usb.device` feature set, which nfd-worker
  discovers from every `/sys/bus/usb/devices` entry regardless of class. No NFD
  worker configuration is needed for this rule to see your camera.
- **The rule is cluster-scoped.** Its name therefore carries a namespace and
  release digest, so two releases in different namespaces get two objects. Two
  rules applying the same label to the same node are harmless: NFD unions the
  labels from every rule that matches.
- **There is no autodiscovery for sensors.** GPIO, i2c, SPI and 1-wire wiring is
  invisible to software, so `indi-allsky.io/sensors` is always something your
  node configuration states explicitly.

## The optional MQTT broker

`mosquitto.enabled: true` renders a single-replica broker, a
`<release>-indi-allsky-mosquitto` Service on `:1883`, and an ingress
NetworkPolicy. Point upstream's `MQTTPUBLISH` at that Service name.

It is deliberately small: a pass-through broker so the capture pipeline has
somewhere to publish, not a durable message store. It keeps no persistence and
writes nothing, so restarting it drops only in-flight messages.

**It has no authentication.** It runs on the image's own
`/mosquitto-no-auth.conf` — `listener 1883`, `allow_anonymous true`. TLS and
credentials are out of scope for v1: if you need either, run your own broker
and leave `mosquitto.enabled` at `false`.

Because there is no authentication, the NetworkPolicy is the broker's only
access control. It admits `:1883` from this release's edge pod and nothing
else — not the web pod, which only renders the MQTT settings in its
configuration form, and not the rest of the namespace.

### Letting your own consumers in

The point of a broker is usually something *else* reading it — Home Assistant, a
dashboard, or the `mqtt_remote_sensor` / `mqtt_remote_libcamera` helpers
upstream ships. Those live outside this release, and the chart cannot select
them without a wildcard that would make the policy a formality.

NetworkPolicies that select the same pod are **unioned**, so admit them with a
policy you own, alongside the chart's:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allsky-mosquitto-consumers
  namespace: allsky
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: indi-allsky
      app.kubernetes.io/instance: allsky      # your release name
      app.kubernetes.io/component: mosquitto
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: home-assistant
      ports:
        - port: 1883
          protocol: TCP
```

Nothing in the chart needs changing, and the chart's own rule keeps working. If
your consumers are outside the cluster entirely, expose the Service the way you
would any other — and remember that anyone who reaches it is an authenticated
client, because there is no authentication.

Setting `networkPolicy.enabled: false` turns off every policy this chart
renders, not just the broker's.

## Topologies that do not exist yet

These are recorded so nobody spends an evening looking for a value that was
never built. **None of them is configurable today**, and no `values.yaml` key
below exists in this release.

### Phase 2 — a floating video worker (`videoWorker.mode: cluster`)

Timelapse, keogram and star-trail generation is the heavy compute in
indi-allsky, and today it runs inside the edge pod on the camera node, at
`nice 19` under a Guaranteed QoS budget. On a Raspberry Pi that is the busiest
the node ever gets, and it happens at night while capture is still running.

VideoWorker is the most separable piece of upstream's daemon: it is driven by
the database `taskqueue`, and only its wake-up is an in-process queue. Phase 2
replaces that nudge so the worker can run as its own floating Deployment
mounting the shared image PVC, selected by `videoWorker.mode: embedded|cluster`
with `embedded` staying the default.

It needs a small upstream code change, which is why it is not here yet: the
patch lives in `patches/` as an **upstream PR candidate** rather than a
permanent fork. Tracked in the roadmap section of
[the README](../README.md#roadmap).

### Documented ceiling — a full capture split

Thin indiserver on the camera node, the whole daemon floating. This is
**documented but not built, and not currently buildable** for the general case:
SensorWorker talks to i2c, 1-wire and GPIO with no network transport, and the
capture and image workers exchange auto-exposure feedback through
`multiprocessing.Array` shared memory. A setup with no local sensors — or with
sensors published over MQTT instead — is the only shape where the split is
even coherent, and it still needs the shared-memory seam addressed upstream.

### Future — a syncapi "web-only" recipe

Upstream ships a syncapi that replicates images from a capture host to a
separate web host. That is the shape for an operator with no `ReadWriteMany`
storage: capture writes locally, the web tier receives over HTTP instead of
sharing a volume. It is a recipe rather than a chart feature — a second release
in web-only mode, plus upstream's own syncapi settings — and it has not been
written or tested yet.

Until it exists, RWX storage is a requirement of this chart whenever the web
pod and the edge pod can land on different nodes.

### Not planned in v1

Multi-camera support, highly-available MariaDB, and first-class libcamera/CSI
camera support. The escape hatch for libcamera is `indiserver.mode: external`
against a host-run indiserver. Focuser control is also a known limitation when
the web pod is not on the camera node: upstream runs focuser moves inside
gunicorn.
