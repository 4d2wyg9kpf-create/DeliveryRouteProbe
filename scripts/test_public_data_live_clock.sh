#!/bin/bash
set -euo pipefail
route_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$route_root/build/logs"
swiftc -parse-as-library \
  "$route_root/DeliveryRouteProbe.swiftpm/APICredentialArchive.swift" \
  "$route_root/DeliveryRouteProbe.swiftpm/PublicDataModels.swift" \
  "$route_root/DeliveryRouteProbe.swiftpm/PublicDataStore.swift" \
  "$route_root/scripts/test_public_data_live_clock.swift" \
  -o "$route_root/build/public-data-live-clock"
"$route_root/build/public-data-live-clock" | tee "$route_root/build/logs/public-data-live-clock.log"
