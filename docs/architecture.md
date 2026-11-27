# Architecture

Four Shelly devices on the LAN are polled over their local HTTP RPC API by an
exporter pod; a dedicated Prometheus in the `energy` namespace keeps the
history; the cluster's existing Grafana in the `monitoring` namespace draws it.
Nothing talks to Shelly Cloud, and nothing is configured on the devices
themselves.

## Why polling, not MQTT

Shelly Gen2+ can push status over MQTT, which is lower latency and would avoid
a scrape interval. It was not chosen because it puts state on the devices: a
broker address, credentials and a topic prefix per device, set through each
device's own web UI. That state is invisible to this repo and would have to be
re-entered by hand after a factory reset — exactly the thing a
version-controlled setup is supposed to eliminate.

Polling keeps the devices as dumb meters. `devices.yaml` plus `make install`
is the entire configuration, and a device that has been reset to defaults is
already compatible.

## Why energy comes from a counter, never from power

Each channel reports both `apower` (instantaneous watts) and
`aenergy.total` (lifetime watt-hours). Only the second is used.

Integrating `apower` over scrape samples looks equivalent and is not: every
missed scrape, pod restart or rollout silently removes that slice of
consumption from the total, and a load that switches on and off between
scrapes is invisible. The device's own counter has already done the
integration in hardware, continuously, whether or not anything was watching.

`shelly_energy_wh_total` is therefore exposed as a Prometheus **counter**.
A factory reset or some firmware updates set it back to zero; `increase()`
treats that as a counter reset and absorbs it, where a gauge would produce a
large negative step.

Units are worth stating because the device mixes them: `aenergy.total` is in
watt-hours, while `aenergy.by_minute` is in **milliwatt**-hours. Confirmed
against a live socket — 3093 mWh in a minute against an `apower` of 186.6 W.

## Why a second Prometheus

Retention in Prometheus is a property of the instance, not of a job. The
Prometheus in the `monitoring` namespace runs with
`--storage.tsdb.retention.time=7d` and `--storage.tsdb.retention.size=1536MB`,
which is right for right-sizing game pods and useless for answering "what did
the freezer cost last winter".

Raising it there would not work either: the same retention applies to every
job, and kubelet, cadvisor and kube-state-metrics are orders of magnitude
larger than this data. The size cap would evict energy history to make room
for container metrics, which is the opposite of what is wanted.

So energy gets its own instance, in its own namespace, with its own PVC and a
three-year retention. The cost is about 128 Mi of RAM; the data itself is
roughly 200 MB a year at 30-second scrapes, which is why a 10 Gi volume and a
three-year window are not extravagant.

If you would rather fold this into the existing Prometheus anyway and live with
7 days, `make print-scrape-config` emits the job to add and
`manifests/prometheus.yaml` can simply not be applied.

## How it reaches Grafana

Grafana runs in-cluster in the `monitoring` namespace, behind Traefik, and gets
its configuration from the kustomization in
`k3s-gameservers/infrastructure/monitoring`.

**Dashboards** need nothing from that repo. Grafana runs the
[kiwigrid sidecar](https://github.com/kiwigrid/k8s-sidecar), which loads any
ConfigMap labelled `grafana_dashboard=1` from any namespace and files it under
the folder named in the `grafana_folder` annotation. `make dashboards` builds
exactly that ConfigMap from `dashboards/*.json`, so the dashboard arrives
declaratively and survives a rebuild.

**The datasource** arrives the same way, from `manifests/datasource.yaml`
labelled `grafana_datasource=1`. That took a change to the platform repo,
because Grafana there originally mounted a single file-provisioned ConfigMap
of datasources — so every new datasource meant editing a file owned by the
gameservers repo, and energy configuration leaked into a repo with no reason to
know about it. Grafana now fills that directory from labelled ConfigMaps
instead, with an init container for cold start and a watcher that POSTs to the
provisioning reload API so a datasource added later needs no restart. Its own
datasources go through the same mechanism, with no special case.

The dashboard defaults to the uid `energy-prometheus`, so nothing has to be
selected once it exists.

Note that the prometheus-operator CRDs are installed on this cluster but no
operator is running, so a `ServiceMonitor` would be silently ignored. Scrape
configuration here is static, matching how the existing Prometheus is
configured.

## Why cost is recorded, not computed at query time

`shelly:cost_eur:increase5m` multiplies each 5-minute energy delta by the
tariff in force during that interval, and the result is stored.

Computing cost in the dashboard instead would multiply historical consumption
by *today's* price. With a flat tariff the error is invisible until the tariff
changes; on a spot tariff that moves every 15 minutes it is wrong immediately.
Recording it freezes the price that actually applied.

The recording rule's `increase()` window and its group `interval` are both
5 minutes on purpose: the samples tile the timeline exactly once, which is
what makes `sum_over_time(...[30d])` a true total rather than an estimate.
Changing one without the other quietly breaks every cost figure.

## Price feed

`https://dashboard.elering.ee/api/nps/price` serves Nord Pool day-ahead prices
for the Baltic and Finnish zones, free and without an API key, in EUR/MWh at
15-minute resolution. The exporter picks the bucket covering now, converts to
EUR/kWh, adds the fixed component from `manifests/tariff.yaml` and applies VAT.

The last known price keeps being served if a refresh fails, because day-ahead
prices are published a day in advance — a transient outage should not punch a
hole in cost accounting. `shelly_price_up` and `shelly_price_age_seconds` are
what to look at if the figures stop moving.

On a flat tariff (`PRICE_MODE=flat`) the contracted price is what cost is
computed from, used exactly as entered — no VAT arithmetic, so it matches the
bill. The market price is still fetched and exposed as a separate component, on
the grounds that the interesting question about a fixed deal is whether it is
beating spot. Both end up on the same panel.

The tariff comes from a gitignored `.env` and reaches the pod as a Secret
rather than a committed ConfigMap. It is not really a secret, but it is nobody
else's business, and it follows the same pattern as
`k3s-gameservers/infrastructure/site.env`.

## Where channel names come from

A name set on the device wins over `devices.yaml`, and `make sync-names` keeps
the two in step by writing this repo's names onto the devices.

The original intent was the opposite: label a socket in the Shelly app, where
you are already standing when you plug something in, and let the graphs follow.
That turns out to be impossible. The app's names are held in the Shelly Cloud
account, not on the device. `Sys.GetConfig`, `Switch.GetConfig`,
`Shelly.GetDeviceInfo`, `KVS.List` and `Group.GetConfig` were all checked on
all four devices, and every local naming field reads back `null` or is absent
— while the switch status reports `source: "SHC"`, the cloud. Reading those
names would mean an authenticated call to an undocumented Cloud endpoint, which
is the dependency this setup exists to avoid.

So `devices.yaml` is the source of truth and `sync-names` pushes it down. The
name ends up local, which is also why it then shows in the app and survives a
cloud outage or an account change.

The trade-off is deliberate: the `name` label is display, not identity.
Renaming a socket ends one series and starts another, so a query that must
survive a rename groups by `device` and `channel`, which are stable. Cost and
energy totals per socket are the ones to watch for this.

Two firmware details, both found the hard way:

- `Switch.SetConfig` must be **POSTed** as a JSON-RPC body. Passing `config=`
  in the query string works until the name contains an escaped quote, at which
  point the firmware's parser fails with a misleading
  `Missing required argument 'id'`.
- Names are free text, so they reach Prometheus as label values and are
  escaped accordingly. `promtool check metrics` on the exporter's output with
  a name containing `"` and `\` passes.

## Host state not in this repo

- **Static DHCP leases** for the four devices. Without them `devices.yaml`
  goes stale whenever the lease pool shuffles. MACs are in the comments there;
  `make discover` re-finds everything if it happens.
- **Device firmware.** Not managed here, and a firmware update can reset the
  energy counters.
- **Authentication.** The devices ship with `auth_en: false`, which means
  anyone on the LAN can switch the sockets. Enabling it is a per-device setting
  in the Shelly web UI; the exporter then needs the password in a
  `shelly-auth` Secret and will use digest auth automatically.

## Device notes

| Device | Model | Channels |
|---|---|---|
| Plug S MTR Gen3 ×2 | `S3PL-30110EU` | `switch:0` |
| 1PM Mini Gen3 | `S3SW-001P8EU` | `switch:0` |
| Power Strip 4 Gen4 | `S4PL-00416EU` | `switch:0`–`switch:3` |

The exporter does not special-case any of them: it walks every `switch:N`
component in `Shelly.GetStatus`, so a device added later works without a code
change.

The Power Strip advertises an alternative Zigbee firmware under
`sys.available_updates.alt`. Do not flash it — it replaces the firmware this
repo talks to. Stay on the default build.

The 1PM Mini sits at about −79 dBm and is the one that will time out. Its
`shelly_up` dropping for a scrape or two is expected; an energy counter does
not lose anything over a missed scrape, which is the other reason for reading
the counter rather than integrating power.
