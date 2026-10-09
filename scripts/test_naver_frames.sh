#!/bin/bash
set -euo pipefail
route_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$route_root/build/logs"
python3 "$route_root/scripts/naver_frame_fixtures.py" &
fixture_pid=$!
trap 'kill "$fixture_pid" 2>/dev/null || true' EXIT
swiftc -parse-as-library "$route_root/DeliveryRouteProbe.swiftpm/MapSupportSource.swift" "$route_root/scripts/test_naver_frames.swift" -o "$route_root/build/naver-frame-tests"
"$route_root/build/naver-frame-tests" | tee "$route_root/build/logs/naver-frames.log"
