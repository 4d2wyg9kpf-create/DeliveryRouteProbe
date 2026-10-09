#!/bin/bash
set -euo pipefail
route_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$route_root/build/logs"
python3 "$route_root/scripts/naver_frame_fixtures.py" &
fixture_pid=$!
trap 'kill "$fixture_pid" 2>/dev/null || true' EXIT
python3 - <<'PY'
import urllib.request, time
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
for port in [8349, 8350, 8351]:
    deadline = time.monotonic() + 5
    while True:
        try:
            with opener.open('http://127.0.0.1:' + str(port) + '/main', timeout=1) as response:
                assert response.status == 200
            break
        except Exception:
            if time.monotonic() >= deadline: raise
            time.sleep(0.1)
print('Local fixture servers reachable')
PY
swiftc -parse-as-library "$route_root/DeliveryRouteProbe.swiftpm/MapSupportSource.swift" "$route_root/scripts/test_naver_frames.swift" -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$route_root/scripts/naver_fixture_info.plist" -o "$route_root/build/naver-frame-tests"
"$route_root/build/naver-frame-tests" | tee "$route_root/build/logs/naver-frames.log"
