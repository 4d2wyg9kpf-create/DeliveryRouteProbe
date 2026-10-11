#!/bin/bash
set -euo pipefail
route_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$route_root/build/logs"
swiftc -parse-as-library \
  "$route_root/DeliveryRouteProbe.swiftpm/DeviceShareModels.swift" \
  "$route_root/DeliveryRouteProbe.swiftpm/DeviceSharingStore.swift" \
  "$route_root/scripts/test_device_sharing.swift" \
  -o "$route_root/build/device-sharing-tests"
"$route_root/build/device-sharing-tests" | tee "$route_root/build/logs/device-sharing.log"
