#!/bin/bash
set -euo pipefail
route_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$route_root/build/logs"
swiftc -parse-as-library "$route_root/DeliveryRouteProbe.swiftpm/MapSupportSource.swift" "$route_root/DeliveryRouteProbe.swiftpm/NaverSharedLink.swift" "$route_root/scripts/test_naver_frames.swift" -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$route_root/scripts/naver_fixture_info.plist" -o "$route_root/build/naver-frame-tests"
python3 -u "$route_root/scripts/naver_frame_fixtures.py" "$route_root/build/naver-frame-tests" | tee "$route_root/build/logs/naver-frames.log"
