#!/bin/bash
set -euo pipefail
route_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$route_root/build/logs"
swiftc -parse-as-library \
  "$route_root/DeliveryRouteProbe.swiftpm/NaverPlaceModels.swift" \
  "$route_root/DeliveryRouteProbe.swiftpm/NaverPlaceEngineSource.swift" \
  "$route_root/DeliveryRouteProbe.swiftpm/NaverAPIEngineSource.swift" \
  "$route_root/DeliveryRouteProbe.swiftpm/NaverCustomerStore.swift" \
  "$route_root/DeliveryRouteProbe.swiftpm/SiteTargetStore.swift" \
  "$route_root/scripts/test_place_destinations.swift" \
  -o "$route_root/build/place-destination-tests"
"$route_root/build/place-destination-tests" | tee "$route_root/build/logs/place-destinations.log"
