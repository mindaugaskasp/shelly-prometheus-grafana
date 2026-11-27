# shelly-prometheus-grafana

Per-socket electricity monitoring for Shelly plugs and power strips on the LAN:
power and energy into Prometheus, historical graphs and real cost in Grafana.
No cloud account, no MQTT broker, nothing configured on the devices themselves.

A rebuilt cluster is one `make install` away from where it was.

## Layout

```
devices.yaml             Device inventory -- the one file you normally edit
Makefile                 install, verify, discover, dashboards
exporter/                Node exporter: Shelly RPC -> Prometheus text
.env.example             Copy to .env (gitignored) -- your price per kWh
manifests/
  namespace.yaml           the energy namespace
  exporter.yaml            exporter Deployment + Service
  prometheus.yaml          dedicated Prometheus, 3y retention
  rules.yaml               energy and cost recording rules
  datasource.yaml          the Grafana datasource, as a labelled ConfigMap
dashboards/
  energy.json              live view: what is drawing power right now
  comparison.json          this period against the last, per channel
docs/architecture.md     Why it is built this way
```

## Setup from scratch

Clone on the k3s host — `make push-image` builds with podman and pushes to the
in-cluster registry on `localhost:30500`, the same way everything else on that
box is delivered. The image tag is the commit, so `make deploy` always runs a
known build and a rollback is just a checkout.

```sh
cp .env.example .env && $EDITOR .env   # your price per kWh; gitignored
make install     # build + push the image, apply everything
make verify      # devices answering, scrape target up, rules loaded
```

`make install` covers everything, including both halves of the Grafana side.
The dashboard and the datasource each ship as a ConfigMap carrying a label
Grafana's sidecars watch for — `grafana_dashboard=1` and
`grafana_datasource=1` — picked up from this namespace without an API token, a
manual import, or a line of energy configuration anywhere else. The dashboard
defaults to the uid `energy-prometheus`, so there is nothing to select either.

The one **prerequisite** is that Grafana runs a datasource sidecar as well as a
dashboard one. On this cluster it does, from
`k3s-gameservers/infrastructure/monitoring/grafana.yaml`. Without it, nothing
reads `manifests/datasource.yaml` and the dashboard comes up with no data; add
the datasource there by hand in that case, or add the sidecar.

If your shell is not already pointed at a readable kubeconfig — k3s's own is
root-only, though `~/.kube/config` on the host works:

```sh
make install KUBECTL="sudo k3s kubectl"
```

## Day-to-day

```sh
make help                          # all targets
make metrics                       # what the exporter is serving right now
make logs                          # tail the exporter
make discover                      # re-scan the subnet for Shelly devices
make probe HOST=192.168.0.128      # raw Shelly.GetStatus from one device
make toggle HOST=192.168.0.128 CH=0  # flip a socket, to map ids to outlets
make port-forward                  # the energy Prometheus UI on :9091
```

## Adding or renaming a device

Edit `devices.yaml`, then `make deploy`. The pod template carries a checksum of
that file, so the exporter restarts and picks it up — a mounted ConfigMap is
only read at startup.

`channels` maps the device's switch id to the name that appears on the graphs.
A plug has only `switch:0`; the Power Strip 4 Gen4 has `switch:0` through
`switch:3`, one per socket.

## Naming sockets

Names live in `devices.yaml`, and `make sync-names` writes them onto the
devices themselves:

```sh
make sync-names DRY=1                  # what it would change
make sync-names                        # write it
make names                             # what the devices call themselves now
make toggle HOST=192.168.0.128 CH=1    # which socket IS this?
```

The names you set in the **Shelly app are not on the hardware** -- they live in
your Shelly Cloud account, and every local naming field on a factory device
reads back `null`. The app therefore cannot be the source of truth here; this
repo is, and `sync-names` makes the devices agree with it. The name then shows
in the app as well, and survives a cloud outage or an account change.

Precedence in the exporter is: the device's own name, then the `channels:`
entry in `devices.yaml`, then `<device>-<switch id>`. A rename shows up within
`META_TTL_MS` (5 minutes). `make set-name` and `make clear-name` write one
socket at a time, for trying a name without editing the file.

One caveat: the `name` label is for reading, not for joining on. A rename
starts a new series under the new name, so anything that has to survive one
should group by `device` and `channel`, which never change.

## Tariff

The price lives in `.env`, which is **gitignored** — copy `.env.example` and
fill it in on the host. `make deploy` turns it into the `shelly-tariff`
Secret, so the price is on the host and in the cluster but never in the repo.

| Key | Meaning |
|---|---|
| `PRICE_MODE` | `flat` for a contracted price, `spot` for day-ahead market pricing |
| `PRICE_FLAT_EUR_PER_KWH` | your price per kWh, exactly as the bill states it, VAT included |
| `PRICE_ENABLED` | `1` fetches the market price too, for comparison; `0` skips the call |
| `PRICE_ZONE` | `lt`, `lv`, `ee` or `fi` |
| `PRICE_FIXED_EUR_PER_KWH` | spot mode only: distribution + margin + excise, excluding VAT |
| `PRICE_VAT_RATE` | spot mode only, e.g. `0.21` |

In `flat` mode `PRICE_FLAT_EUR_PER_KWH` is used exactly as entered — nothing is
added to it — and it is what cost is computed from. The market price is still
fetched and graphed beside it, so you can see whether the fixed deal is beating
spot. Spot prices come from Elering's free Nord Pool API: no key, 15-minute
resolution.

## Metrics

Per channel, labelled `device`, `channel` and `name`:

| Metric | |
|---|---|
| `shelly_power_watts` | instantaneous active power |
| `shelly_energy_wh_total` | **counter** — lifetime Wh, the basis for all energy and cost |
| `shelly_voltage_volts`, `shelly_current_amperes`, `shelly_frequency_hertz`, `shelly_power_factor` | |
| `shelly_output_on` | relay state |
| `shelly_temperature_celsius` | on devices that report it |

Per device: `shelly_up`, `shelly_info`, `shelly_uptime_seconds`,
`shelly_wifi_rssi_dbm`, `shelly_cloud_connected`, `shelly_mqtt_connected`,
`shelly_firmware_update_available`, `shelly_scrape_duration_seconds`.

Price: `shelly_price_eur_per_kwh{component="total"|"flat"|"spot"|"fixed"}`
(`total` is what cost is computed from), `shelly_price_mode`,
`shelly_price_up`, `shelly_price_age_seconds`.

Recorded every 5 minutes: `shelly:energy_kwh:increase5m`,
`shelly:cost_eur:increase5m`, `shelly:cost_eur_spot:increase5m`,
`shelly:power_watts:sum`, and `:sum` variants of the three per-channel ones.

`shelly:cost_eur_spot:increase5m` prices the same consumption at the market
rate rather than your tariff. The difference between the two is what the fixed
deal is worth, and it has to be recorded as it happens for the same reason
cost does.

## Comparing periods

The second dashboard answers "is it getting worse" rather than "what is
happening now". Pick a range and every panel compares it with the window of
the same length immediately before it -- **Last 30 days** against the 30 days
before that, **Today** against yesterday -- per channel, in kWh and in euros
at the prices that applied.

| Panel | |
|---|---|
| Cost / energy for the range | and the percentage change against the period before |
| At this rate, 30 days | the range scaled up, for a quick monthly figure |
| By channel, before and after | the sortable version: which socket moved and by how much |
| Cost per day, both periods | the old window shifted onto the same axis, day against day |
| kWh per day, by channel | stacked daily bars |
| Where the money went | cost per channel over the range |
| What never switching off costs | each channel's **lowest** draw in the range, priced for a year |
| Your fixed deal against the market | what spot would have cost, minus what you paid |

Three things worth knowing about it:

- Comparison is `offset $__range`, not calendar months. PromQL has no concept
  of a month, so "October against November" is approximated by two equal
  windows. The daily bars are there to read calendar boundaries off directly.
- The *before* columns stay blank until there is twice the selected range in
  history. A 30-day comparison needs 60 days of data.
- Daily buckets are UTC days, because that is where Prometheus puts a 1-day
  step. Two hours of a local day land in the neighbouring bar.

## Useful queries

```promql
# kWh this month, per channel
sum_over_time(shelly:energy_kwh:increase5m[30d])

# EUR this month, at the prices that actually applied
sum_over_time(shelly:cost_eur:increase5m[30d])

# What it would cost to leave this running for a year
shelly_power_watts * 8.76 * scalar(shelly_price_eur_per_kwh{component="total"})

# Standby draw: channels on but under 5 W
shelly_power_watts < 5 and shelly_output_on == 1
```

Energy and cost totals come from the recorded 5-minute deltas rather than from
`increase()` over a long range, because the recorded series tiles the timeline
exactly and carries the historical price. See `docs/architecture.md`.

## Things worth knowing

- **Give the devices static DHCP leases.** `devices.yaml` holds IP addresses;
  MACs are in the comments so leases can be pinned without re-scanning.
- **The devices have no authentication by default** — anyone on the LAN can
  switch the sockets. Enable it per device in the Shelly UI, then
  `kubectl create secret generic shelly-auth -n energy --from-literal=password=...`
  and the exporter will use digest auth.
- **Do not flash the Power Strip's alternative Zigbee firmware**; it replaces
  the API this repo uses.
- **A firmware update can reset the energy counters.** Harmless for history
  — `increase()` handles it — but the lifetime figure on the device restarts.
- `make uninstall` deletes the namespace **and the PVC holding the history**.
  It asks first.
