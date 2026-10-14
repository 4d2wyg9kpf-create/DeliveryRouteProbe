#!/bin/bash
set -euo pipefail
route_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$route_root/build/logs"
swiftc -parse-as-library "$route_root/DeliveryRouteProbe.swiftpm/BuildingEvaluation.swift" "$route_root/DeliveryRouteProbe.swiftpm/BuildingComplex.swift" "$route_root/scripts/test_building_complex.swift" -o "$route_root/build/building-complex-tests"
"$route_root/build/building-complex-tests" | tee "$route_root/build/logs/building-complex.log"
