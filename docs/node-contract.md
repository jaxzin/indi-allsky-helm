# Node contract

How this chart decides where capture runs, and what it asks of your nodes.

indi-allsky has one hard physical dependency: the node the camera (and any
sensors) are plugged into. The chart expresses that dependency through two
node labels. Everything else — web UI, database, optional MQTT broker —
floats on ordinary cluster compute.

## The two labels

### `indi-allsky.io/camera: "true"`

Promises that this node has the all-sky camera attached. Labeling the node
yourself is the documented baseline:

```sh
kubectl label node cam01.example.com indi-allsky.io/camera=true
```

Optionally, [Node Feature Discovery](https://github.com/kubernetes-sigs/node-feature-discovery)
can autodiscover USB astro cameras and apply the label for you — see the
`discovery.nfd.*` values. Note that NFD's `usb` source only reports device
classes on its `deviceClassWhitelist`, so you may need to extend the NFD
worker configuration before your camera shows up. Fuller NFD guidance is
coming with the discovery documentation.

### `indi-allsky.io/sensors: "true"`

Promises that this node is wired to environmental sensor hardware over GPIO,
i2c, SPI, or 1-wire. This label is **always applied manually** — physical
wiring is invisible to software discovery, so no autodiscovery exists for it:

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
| `edge.sensors.enabled` | `true` | Adds the sensors label to the node selector and mounts sensor devices |

## Security posture

The chart is hardened by default: every container runs under a restricted
security context (no privilege escalation, all capabilities dropped, default
seccomp profile) except the device-attached edge containers, and no pod
mounts a service-account token.

## Coming

- **Device access and host preparation** — the device modes
  (`edge.devices.mode`) and the node prerequisites they assume (i2c enabled,
  1-wire overlay, udev rules) are coming with the edge workload
  documentation.
- **Topology examples** — sharing the camera node under the capture
  PriorityClass versus dedicating it with a taint (for example
  `example.com/dedicated=allsky:NoSchedule` plus matching
  `edge.tolerations`) are coming with the scheduling documentation.
