#!/bin/bash
set -euo pipefail
route_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$route_root/build/logs"
python3 "$route_root/scripts/naver_frame_fixtures.py" &
fixture_pid=$!
trap 'kill "$fixture_pid" 2>/dev/null || true' EXIT
python3 - <<'PY'
import urllib.request
for host in ['localhost', '127.0.0.1', '127.0.0.2']:
    with urllib.request.urlopen('http://' + host + ':8349/main', timeout=5) as response:
        assert response.status == 200
print('Local fixture servers reachable')
PY
swiftc -parse-as-library "$route_root/DeliveryRouteProbe.swiftpm/MapSupportSource.swift" "$route_root/scripts/test_naver_frames.swift" -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$route_root/scripts/naver_fixture_info.plist" -o "$route_root/build/naver-frame-tests"
"$route_root/build/naver-frame-tests" | tee "$route_root/build/logs/naver-frames.log"
