#!/usr/bin/env python3
"""Push the names in devices.yaml onto the Shelly devices themselves.

The names you set in the Shelly app live in your Shelly Cloud account, not on
the hardware: every local naming field on a factory device reads back null.
Writing them to the devices instead means the label is local, survives a cloud
outage or an account change, shows up in the app, and is what the exporter
reads -- so devices.yaml is where you type a name and this is what makes it
stick.

Re-runnable: a device already holding the right name is left alone.
"""

import json
import sys
import urllib.error
import urllib.request

try:
    import yaml
except ModuleNotFoundError:
    sys.exit("PyYAML is missing: pip install pyyaml, or run this on the k3s host")

TIMEOUT = 8


def rpc(host, method, params):
    body = json.dumps({"id": 1, "method": method, "params": params}).encode()
    req = urllib.request.Request(
        f"http://{host}/rpc",
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=TIMEOUT) as res:
        payload = json.load(res)
    if "error" in payload:
        raise RuntimeError(payload["error"])
    return payload.get("result")


def get_config(host):
    req = urllib.request.Request(f"http://{host}/rpc/Shelly.GetConfig")
    with urllib.request.urlopen(req, timeout=TIMEOUT) as res:
        return json.load(res)


def main():
    args = sys.argv[1:]
    dry_run = "--dry-run" in args
    paths = [a for a in args if not a.startswith("--")]
    devices_file = paths[0] if paths else "devices.yaml"

    with open(devices_file, encoding="utf-8") as fh:
        doc = yaml.safe_load(fh) or {}

    changed = failed = already = 0

    for device in doc.get("devices") or []:
        name, host = device.get("name"), device.get("host")
        if not name or not host:
            print(f"!! skipping malformed entry: {device!r}", file=sys.stderr)
            failed += 1
            continue

        try:
            config = get_config(host)
        except (urllib.error.URLError, OSError, ValueError) as err:
            print(f"!! {name} ({host}): unreachable: {err}", file=sys.stderr)
            failed += 1
            continue

        print(f"{name} ({host})")

        # The device's own name, so the app lists it the way this repo does.
        wanted = [("Sys", None, name, (config.get("sys") or {}).get("device", {}).get("name"))]

        # channels: maps a switch id to the name that should be on the graphs.
        for raw_id, channel_name in (device.get("channels") or {}).items():
            key = f"switch:{raw_id}"
            if key not in config:
                print(f"  !! {key} does not exist on this device", file=sys.stderr)
                failed += 1
                continue
            wanted.append(("Switch", int(raw_id), channel_name, config[key].get("name")))

        for kind, switch_id, want, have in wanted:
            label = "device" if kind == "Sys" else f"switch:{switch_id}"
            if have == want:
                print(f"  = {label}: already {want!r}")
                already += 1
                continue
            if dry_run:
                print(f"  ~ {label}: {have!r} -> {want!r}  (dry run)")
                changed += 1
                continue
            try:
                if kind == "Sys":
                    rpc(host, "Sys.SetConfig", {"config": {"device": {"name": want}}})
                else:
                    rpc(host, "Switch.SetConfig",
                        {"id": switch_id, "config": {"name": want}})
            except (urllib.error.URLError, OSError, ValueError, RuntimeError) as err:
                print(f"  !! {label}: {err}", file=sys.stderr)
                failed += 1
                continue
            print(f"  + {label}: {have!r} -> {want!r}")
            changed += 1

    verb = "would change" if dry_run else "changed"
    print(f"\n{verb} {changed}, already correct {already}, failed {failed}")
    if not dry_run and changed:
        print("The exporter relabels within META_TTL_MS (5 minutes by default).")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
