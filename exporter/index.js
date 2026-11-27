'use strict';
// Polls Shelly Gen2+ devices over the LAN HTTP RPC API and serves the result
// as Prometheus metrics. Nothing is configured on the devices themselves --
// no MQTT, no cloud, no per-device state -- so a rebuilt cluster needs only
// this deployment and devices.yaml to be back where it was.

const http = require('node:http');
const fs = require('node:fs');
const crypto = require('node:crypto');
const YAML = require('yaml');

const PORT = Number(process.env.PORT || 9102);
const DEVICES_FILE = process.env.DEVICES_FILE || '/etc/shelly/devices.yaml';
const DEFAULT_TIMEOUT_MS = Number(process.env.TIMEOUT_MS || 4000);
// Gen2+ digest auth is always for the user "admin"; unset means auth is off,
// which is the device default.
const SHELLY_PASSWORD = process.env.SHELLY_PASSWORD || '';

const PRICE_ENABLED = process.env.PRICE_ENABLED !== '0';
const PRICE_ZONE = (process.env.PRICE_ZONE || 'lt').toLowerCase();
const PRICE_URL = process.env.PRICE_URL || 'https://dashboard.elering.ee/api/nps/price';
// Everything that is not the spot price: distribution, supplier margin,
// excise. EUR per kWh, excluding VAT.
const PRICE_FIXED = Number(process.env.PRICE_FIXED_EUR_PER_KWH || 0);
const PRICE_VAT = Number(process.env.PRICE_VAT_RATE || 0);
const PRICE_REFRESH_MS = Number(process.env.PRICE_REFRESH_MS || 15 * 60 * 1000);

// ---------------------------------------------------------------- devices

function loadDevices() {
  const doc = YAML.parse(fs.readFileSync(DEVICES_FILE, 'utf8')) || {};
  const defaults = doc.defaults || {};
  const devices = (doc.devices || []).map((d) => ({
    name: d.name,
    host: d.host,
    timeoutMs: Number(d.timeoutMs || defaults.timeoutMs || DEFAULT_TIMEOUT_MS),
    // { "<switch id>": "friendly name" }
    channels: d.channels || {},
  }));
  for (const d of devices) {
    if (!d.name || !d.host) {
      throw new Error(`device entry needs both name and host: ${JSON.stringify(d)}`);
    }
  }
  return devices;
}

let devices = [];
try {
  devices = loadDevices();
  console.log(`loaded ${devices.length} device(s) from ${DEVICES_FILE}`);
} catch (err) {
  console.error(`cannot read ${DEVICES_FILE}: ${err.message}`);
  process.exit(1);
}

// ------------------------------------------------------------ digest auth

// Shelly's Gen2 digest is standard except that HA2 is the literal string
// "dummy_method:dummy_uri" rather than the real method and path.
function digestHeader(challenge, password) {
  const p = {};
  for (const part of challenge.replace(/^Digest\s+/i, '').split(',')) {
    const i = part.indexOf('=');
    if (i === -1) continue;
    p[part.slice(0, i).trim()] = part.slice(i + 1).trim().replace(/^"|"$/g, '');
  }
  const algo = (p.algorithm || 'SHA-256').toUpperCase() === 'SHA-256' ? 'sha256' : 'md5';
  const h = (s) => crypto.createHash(algo).update(s).digest('hex');
  const cnonce = crypto.randomBytes(8).toString('hex');
  const nc = '00000001';
  const ha1 = h(`admin:${p.realm}:${password}`);
  const ha2 = h('dummy_method:dummy_uri');
  const response = h(`${ha1}:${p.nonce}:${nc}:${cnonce}:auth:${ha2}`);
  return (
    `Digest username="admin", realm="${p.realm}", nonce="${p.nonce}", ` +
    `uri="/rpc/Shelly.GetStatus", algorithm=${p.algorithm || 'SHA-256'}, ` +
    `qop=auth, nc=${nc}, cnonce="${cnonce}", response="${response}"`
  );
}

async function rpc(device, path) {
  const url = `http://${device.host}${path}`;
  const fetchOnce = async (headers) => {
    const ctl = new AbortController();
    const t = setTimeout(() => ctl.abort(), device.timeoutMs);
    try {
      return await fetch(url, { headers, signal: ctl.signal });
    } finally {
      clearTimeout(t);
    }
  };

  let res = await fetchOnce({});
  if (res.status === 401) {
    if (!SHELLY_PASSWORD) {
      throw new Error('device requires auth but SHELLY_PASSWORD is not set');
    }
    const challenge = res.headers.get('www-authenticate') || '';
    res = await fetchOnce({ Authorization: digestHeader(challenge, SHELLY_PASSWORD) });
  }
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  return res.json();
}

const getStatus = (device) => rpc(device, '/rpc/Shelly.GetStatus');

// Model, generation and firmware come from /shelly, not from GetStatus. They
// change only on a firmware update, so they are cached rather than fetched
// on every scrape.
const INFO_TTL_MS = 60 * 60 * 1000;
const infoCache = new Map();

async function getInfo(device) {
  const cached = infoCache.get(device.name);
  if (cached && Date.now() - cached.at < INFO_TTL_MS) return cached.info;
  try {
    const info = await rpc(device, '/shelly');
    infoCache.set(device.name, { at: Date.now(), info });
    return info;
  } catch (err) {
    console.error(`${device.name}: /shelly failed: ${err.message}`);
    return cached ? cached.info : null;
  }
}

// ------------------------------------------------------------ price feed

const price = { ok: false, spot: 0, updated: 0 };

async function refreshPrice() {
  try {
    const ctl = new AbortController();
    const t = setTimeout(() => ctl.abort(), 10000);
    let body;
    try {
      const res = await fetch(PRICE_URL, { signal: ctl.signal });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      body = await res.json();
    } finally {
      clearTimeout(t);
    }
    const series = body && body.data && body.data[PRICE_ZONE];
    if (!Array.isArray(series) || series.length === 0) {
      throw new Error(`no series for zone "${PRICE_ZONE}"`);
    }
    // Buckets are 15 minutes and arrive for today and (after ~14:00 CET)
    // tomorrow. Take the latest bucket that has already started.
    const now = Math.floor(Date.now() / 1000);
    const current = series.filter((p) => p.timestamp <= now).pop();
    if (!current) throw new Error('no bucket covering now');
    // Elering quotes EUR/MWh excluding VAT.
    price.spot = Number(current.price) / 1000;
    price.updated = current.timestamp;
    price.ok = true;
  } catch (err) {
    price.ok = false;
    console.error(`price refresh failed: ${err.message}`);
  }
}

if (PRICE_ENABLED) {
  refreshPrice();
  setInterval(refreshPrice, PRICE_REFRESH_MS).unref();
}

// -------------------------------------------------------------- rendering

function esc(v) {
  return String(v).replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, '\\n');
}

// Samples are buffered per metric name rather than written as they arrive, so
// that each family is emitted once with its HELP/TYPE and all of its series
// together. Devices are scraped concurrently, which would otherwise interleave
// families in the output.
class Metrics {
  constructor() {
    this.families = new Map();
  }

  add(name, type, help, labels, value) {
    if (value === undefined || value === null || Number.isNaN(Number(value))) return;
    let family = this.families.get(name);
    if (!family) {
      family = { type, help, samples: [] };
      this.families.set(name, family);
    }
    if (!family.help && help) family.help = help;
    const l = Object.entries(labels)
      .filter(([, v]) => v !== undefined && v !== null && v !== '')
      .map(([k, v]) => `${k}="${esc(v)}"`)
      .join(',');
    family.samples.push(l ? `${name}{${l}} ${Number(value)}` : `${name} ${Number(value)}`);
  }

  toString() {
    const out = [];
    for (const [name, family] of this.families) {
      out.push(`# HELP ${name} ${family.help}`, `# TYPE ${name} ${family.type}`);
      out.push(...family.samples.sort());
    }
    return out.join('\n') + '\n';
  }
}

function collectDevice(m, device, status, info, ok, durationS, errMsg) {
  const base = { device: device.name };
  m.add('shelly_up', 'gauge', 'Whether the last scrape of this device succeeded.', base, ok ? 1 : 0);
  m.add(
    'shelly_scrape_duration_seconds', 'gauge',
    'How long the Shelly.GetStatus call to this device took.', base, durationS,
  );
  if (!ok) {
    if (errMsg) console.error(`${device.name} (${device.host}): ${errMsg}`);
    return;
  }

  const sys = status.sys || {};
  m.add(
    'shelly_info', 'gauge', 'Device identity; the value is always 1.',
    {
      ...base,
      host: device.host,
      mac: sys.mac,
      model: info ? info.model : '',
      gen: info ? info.gen : '',
      app: info ? info.app : '',
      firmware: info ? info.ver : '',
    },
    1,
  );
  m.add('shelly_uptime_seconds', 'gauge', 'Device uptime.', base, sys.uptime);
  m.add(
    'shelly_firmware_update_available', 'gauge',
    'Whether the device reports a pending stable firmware update.',
    base, sys.available_updates && sys.available_updates.stable ? 1 : 0,
  );
  if (status.wifi) {
    m.add('shelly_wifi_rssi_dbm', 'gauge', 'WiFi signal strength.', base, status.wifi.rssi);
  }
  if (status.cloud) {
    m.add(
      'shelly_cloud_connected', 'gauge',
      'Whether the device currently holds a connection to Shelly Cloud.',
      base, status.cloud.connected ? 1 : 0,
    );
  }
  if (status.mqtt) {
    m.add(
      'shelly_mqtt_connected', 'gauge', 'Whether the device is connected to an MQTT broker.',
      base, status.mqtt.connected ? 1 : 0,
    );
  }

  // Every metered output is a "switch:N" component, whatever the device is:
  // a single plug has switch:0, the 4-socket strip has switch:0..3.
  for (const [key, sw] of Object.entries(status)) {
    const match = /^switch:(\d+)$/.exec(key);
    if (!match) continue;
    const id = match[1];
    const labels = {
      ...base,
      channel: id,
      name: (device.channels && device.channels[id]) || `${device.name}-${id}`,
    };

    m.add('shelly_power_watts', 'gauge', 'Instantaneous active power.', labels, sw.apower);
    m.add('shelly_voltage_volts', 'gauge', 'Measured voltage.', labels, sw.voltage);
    m.add('shelly_current_amperes', 'gauge', 'Measured current.', labels, sw.current);
    m.add('shelly_frequency_hertz', 'gauge', 'Mains frequency.', labels, sw.freq);
    m.add('shelly_power_factor', 'gauge', 'Power factor, where the device reports one.', labels, sw.pf);
    m.add('shelly_output_on', 'gauge', 'Relay state: 1 when the output is closed.', labels, sw.output ? 1 : 0);

    // The lifetime Wh counter is the only safe basis for energy and cost:
    // integrating shelly_power_watts would silently under-count across
    // scrape gaps. Exposed as a counter so increase() absorbs the reset to
    // zero that a factory reset or some firmware updates cause.
    if (sw.aenergy && sw.aenergy.total !== undefined) {
      m.add(
        'shelly_energy_wh_total', 'counter',
        'Lifetime active energy through this channel, in watt-hours.',
        labels, sw.aenergy.total,
      );
    }
    if (sw.ret_aenergy && sw.ret_aenergy.total !== undefined) {
      m.add(
        'shelly_returned_energy_wh_total', 'counter',
        'Lifetime returned active energy, in watt-hours.',
        labels, sw.ret_aenergy.total,
      );
    }
    if (sw.temperature && sw.temperature.tC !== undefined) {
      m.add(
        'shelly_temperature_celsius', 'gauge',
        'Internal temperature, on devices that report one.',
        labels, sw.temperature.tC,
      );
    }
  }
}

function collectPrice(m) {
  const zone = { zone: PRICE_ZONE };

  // The price family is always exposed, so the cost recording rules have
  // something to multiply by in every configuration. With PRICE_ENABLED=0 the
  // spot component stays at zero and "total" is just the flat tariff; with a
  // failed refresh the last known spot price keeps being served, because
  // day-ahead prices are published a day in advance and a transient outage
  // should not punch a hole in cost accounting. shelly_price_up and
  // shelly_price_age_seconds are what to alert on.
  m.add(
    'shelly_price_up', 'gauge',
    'Whether the last spot price refresh succeeded. Always 1 when the spot feed is disabled.',
    {}, PRICE_ENABLED ? (price.ok ? 1 : 0) : 1,
  );
  if (PRICE_ENABLED) {
    m.add(
      'shelly_price_age_seconds', 'gauge',
      'Age of the market interval the served spot price came from.',
      zone, price.updated ? Math.floor(Date.now() / 1000) - price.updated : NaN,
    );
    m.add(
      'shelly_price_bucket_timestamp_seconds', 'gauge',
      'Start of the 15-minute market interval the current price came from.',
      zone, price.updated || NaN,
    );
  }

  const spot = PRICE_ENABLED ? price.spot : 0;
  const total = (spot + PRICE_FIXED) * (1 + PRICE_VAT);
  m.add(
    'shelly_price_eur_per_kwh', 'gauge',
    'Electricity price per kWh. "spot" is the raw day-ahead market price, "fixed" is distribution plus supplier margin and excise, "total" is both with VAT applied.',
    { ...zone, component: 'spot' }, spot,
  );
  m.add('shelly_price_eur_per_kwh', 'gauge', '', { ...zone, component: 'fixed' }, PRICE_FIXED);
  m.add('shelly_price_eur_per_kwh', 'gauge', '', { ...zone, component: 'total' }, total);
}

// ----------------------------------------------------------------- server

let scrapeErrors = 0;

async function scrapeAll() {
  const m = new Metrics();
  // Devices are polled in parallel with each other, but each device gets a
  // single in-flight request: these are single-threaded ESP32 web servers.
  await Promise.all(
    devices.map(async (device) => {
      const started = process.hrtime.bigint();
      try {
        const status = await getStatus(device);
        const durationS = Number(process.hrtime.bigint() - started) / 1e9;
        collectDevice(m, device, status, await getInfo(device), true, durationS);
      } catch (err) {
        const durationS = Number(process.hrtime.bigint() - started) / 1e9;
        scrapeErrors += 1;
        collectDevice(m, device, null, null, false, durationS, err.message);
      }
    }),
  );
  collectPrice(m);
  m.add(
    'shelly_exporter_scrape_errors_total', 'counter',
    'Device scrapes that failed since the exporter started.', {}, scrapeErrors,
  );
  m.add('shelly_exporter_devices', 'gauge', 'Devices configured in devices.yaml.', {}, devices.length);
  return m.toString();
}

const server = http.createServer(async (req, res) => {
  if (req.url === '/healthz') {
    res.writeHead(200, { 'Content-Type': 'text/plain' }).end('ok\n');
    return;
  }
  if (req.url !== '/metrics' && req.url !== '/') {
    res.writeHead(404, { 'Content-Type': 'text/plain' }).end('not found\n');
    return;
  }
  try {
    const body = await scrapeAll();
    res.writeHead(200, { 'Content-Type': 'text/plain; version=0.0.4' }).end(body);
  } catch (err) {
    console.error(`scrape failed: ${err.stack || err.message}`);
    res.writeHead(500, { 'Content-Type': 'text/plain' }).end(`scrape failed: ${err.message}\n`);
  }
});

server.listen(PORT, () => {
  console.log(`shelly-exporter listening on :${PORT}/metrics`);
});

for (const sig of ['SIGTERM', 'SIGINT']) {
  process.on(sig, () => server.close(() => process.exit(0)));
}
