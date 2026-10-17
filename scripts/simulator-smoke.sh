#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build

device_id=$(xcrun simctl list devices available --json | python3 -c '
import json, sys
devices = [d for group in json.load(sys.stdin)["devices"].values() for d in group
           if d.get("isAvailable") and d["name"].startswith("iPhone")]
if not devices:
    raise SystemExit("No available iPhone simulator")
devices.sort(key=lambda d: d.get("state") != "Booted")
print(devices[0]["udid"])
')

state=$(xcrun simctl list devices --json | python3 -c '
import json, sys
device_id = sys.argv[1]
print(next(d["state"] for group in json.load(sys.stdin)["devices"].values()
           for d in group if d["udid"] == device_id))
' "$device_id")
if [ "$state" != "Booted" ]; then
  xcrun simctl boot "$device_id"
fi
xcrun simctl bootstatus "$device_id" -b
xcrun simctl install "$device_id" DerivedData/Build/Products/Debug-iphonesimulator/Ordnungsplaner.app
xcrun simctl launch "$device_id" local.ordnungsplaner.app
sleep 4
xcrun simctl io "$device_id" screenshot build/Ordnungsplaner-Simulator.png
