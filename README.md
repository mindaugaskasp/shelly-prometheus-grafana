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
manifests/
  namespace.yaml           the energy namespace
  tariff.yaml              price zone, fixed charges, VAT
  exporter.yaml            exporter Deployment + Service
  prometheus.yaml          dedicated Prometheus, 3y retention
  rules.yaml               energy and cost recording rules
dashboards/energy.json   Grafana dashboard, shipped as a labelled ConfigMap
docs/architecture.md     Why it is built this way
```

## Setup from scratch

Clone on the k3s host — `make import-image` builds with podman and loads
straight into containerd, so no registry is involved.

```sh
make install     # build + import the image, apply everything, load the dashboard
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

## Tariff

`manifests/tariff.yaml` holds the price settings, committed on purpose:

| Key | Meaning |
|---|---|
| `PRICE_ENABLED` | `1` for Nord Pool day-ahead pricing, `0` for a flat tariff |
| `PRICE_ZONE` | `lt`, `lv`, `ee` or `fi` |
| `PRICE_FIXED_EUR_PER_KWH` | distribution + supplier margin + excise, excluding VAT |
| `PRICE_VAT_RATE` | e.g. `0.21` |

**The committed values are placeholders.** Take the fixed component from your
supplier's price list, or cost figures will be confidently wrong. For a flat
tariff set `PRICE_ENABLED: "0"` and put the whole per-kWh price, excluding VAT,
in `PRICE_FIXED_EUR_PER_KWH`.

Spot prices come from Elering's free Nord Pool API — no key, 15-minute
resolution, EUR/MWh.

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

Price: `shelly_price_eur_per_kwh{component="spot"|"fixed"|"total"}`,
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
