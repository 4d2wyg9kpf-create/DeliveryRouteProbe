#!/bin/bash
set -euo pipefail
route_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$route_root/build/logs"
swiftc -parse-as-library \
  "$route_root/DeliveryRouteProbe.swiftpm/DeliveryDepartureTime.swift" \
  "$route_root/scripts/test_departure_time.swift" \
  -o "$route_root/build/departure-time-tests"
"$route_root/build/departure-time-tests" | tee "$route_root/build/logs/departure-time.log"
