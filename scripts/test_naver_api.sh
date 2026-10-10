#!/bin/bash
set -euo pipefail
route_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$route_root/build/logs"
swiftc -parse-as-library \
  "$route_root/DeliveryRouteProbe.swiftpm/APICredentialArchive.swift" \
  "$route_root/DeliveryRouteProbe.swiftpm/NaverPlaceModels.swift" \
  "$route_root/DeliveryRouteProbe.swiftpm/NaverPlaceEngineSource.swift" \
  "$route_root/DeliveryRouteProbe.swiftpm/NaverAPIEngineSource.swift" \
  "$route_root/DeliveryRouteProbe.swiftpm/NaverAPIStore.swift" \
  "$route_root/scripts/test_naver_api.swift" \
  -o "$route_root/build/naver-api-tests"
"$route_root/build/naver-api-tests" | tee "$route_root/build/logs/naver-api.log"
