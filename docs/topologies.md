# Topologies

Where the pieces run, and the choices that decide it. This is a seed — the
fuller discovery and deployment guidance lands with the documentation task.

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
