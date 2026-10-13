#!/bin/bash
set -euo pipefail
route_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$route_root/build/logs"
swiftc -parse-as-library \
  "$route_root/DeliveryRouteProbe.swiftpm/DeviceShareModels.swift" \
  "$route_root/DeliveryRouteProbe.swiftpm/EvaluationReference.swift" \
  "$route_root/DeliveryRouteProbe.swiftpm/EvaluationReferenceStore.swift" \
  "$route_root/scripts/test_evaluation_reference.swift" \
  -o "$route_root/build/evaluation-reference-tests"
"$route_root/build/evaluation-reference-tests" | tee "$route_root/build/logs/evaluation-reference.log"
