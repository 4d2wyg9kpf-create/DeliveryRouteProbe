#!/bin/bash
set -euo pipefail
route_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$route_root/build/logs"
swiftc -parse-as-library "$route_root/DeliveryRouteProbe.swiftpm/BuildingEvaluation.swift" "$route_root/scripts/test_building_evaluation.swift" -o "$route_root/build/building-evaluation-tests"
"$route_root/build/building-evaluation-tests" | tee "$route_root/build/logs/building-evaluation.log"
