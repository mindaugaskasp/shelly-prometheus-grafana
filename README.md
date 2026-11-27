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
dashboards/energy.json   Grafana dashboard, shipped as a labelled ConfigMap
docs/architecture.md     Why it is built this way
```

## Setup from scratch

Clone on the k3s host — `make push-image` builds with podman and pushes to the
in-cluster registry on `localhost:30500`, the same way everything else on that
box is delivered. The image tag is the commit, so `make deploy` always runs a
known build and a rollback is just a checkout.

```sh
cp .env.example .env && $EDITOR .env   # your price per kWh; gitignored
make install     # build + push the image, apply everything, load the dashboard
make verify      # devices answering, scrape target up, rules loaded
make datasource  # prints the one thing this repo cannot apply for you
```

`make install` covers everything in-cluster, including the dashboard: Grafana's
sidecar picks up any ConfigMap labelled `grafana_dashboard=1`, so no API token
and no manual import.

The **datasource** is the single one-time step outside this repo. Grafana
file-provisions datasources from
`k3s-gameservers/infrastructure/monitoring/config/datasources.yaml`, so add the
four lines `make datasource` prints and re-run that kustomization. The
dashboard defaults to the uid `energy-prometheus`, so once it exists there is
nothing to select.

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

The label on the graphs comes from the name set **on the device**, which is
also the name the Shelly app shows. Set it once and it follows the socket
everywhere:

```sh
make names                                                   # what they call themselves now
make set-name HOST=192.168.0.128 CH=1 NAME="Freezer"         # name a socket
make clear-name HOST=192.168.0.128 CH=1                      # hand it back to devices.yaml
make toggle HOST=192.168.0.128 CH=1                          # which socket IS this?
```

Precedence is: the device's own name, then the `channels:` fallback in
`devices.yaml`, then `<device>-<switch id>`. Renaming shows up within
`META_TTL_MS` (5 minutes).

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
`shelly:cost_eur:increase5m`, `shelly:power_watts:sum`, and `:sum` variants of
the first two.

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
