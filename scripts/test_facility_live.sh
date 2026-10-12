#!/bin/bash
set -euo pipefail
route_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$route_root"
mkdir -p build/logs
swiftc -parse-as-library DeliveryRouteProbe.swiftpm/KakaoRouteModels.swift DeliveryRouteProbe.swiftpm/FacilityRouting.swift DeliveryRouteProbe.swiftpm/FacilityRouteWebScript.swift DeliveryRouteProbe.swiftpm/FacilityRouteBrowser.swift scripts/test_facility_live.swift -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker scripts/naver_fixture_info.plist -o build/facility-live-tests
build/facility-live-tests | tee build/logs/facility-live.log
