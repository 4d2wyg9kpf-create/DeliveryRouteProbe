#!/bin/bash
set -euo pipefail
route_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$route_root/build/logs"
swiftc -parse-as-library \
  "$route_root/DeliveryRouteProbe.swiftpm/NaverSharedLink.swift" \
  "$route_root/DeliveryRouteProbe.swiftpm/NaverSharedLinkResolver.swift" \
  "$route_root/DeliveryRouteProbe.swiftpm/NaverPlaceModels.swift" \
  "$route_root/DeliveryRouteProbe.swiftpm/NaverPlaceEngineSource.swift" \
  "$route_root/scripts/test_shared_links.swift" \
  -o "$route_root/build/shared-link-tests"
"$route_root/build/shared-link-tests" | tee "$route_root/build/logs/shared-links.log"
