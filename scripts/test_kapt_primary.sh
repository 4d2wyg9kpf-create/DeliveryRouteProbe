#!/bin/bash
set -euo pipefail
route_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$route_root"
mkdir -p build/logs
swiftc -parse-as-library \
  DeliveryRouteProbe.swiftpm/DeviceShareModels.swift \
  DeliveryRouteProbe.swiftpm/APICredentialArchive.swift \
  DeliveryRouteProbe.swiftpm/KakaoRouteModels.swift \
  DeliveryRouteProbe.swiftpm/KakaoDistanceArchive.swift \
  DeliveryRouteProbe.swiftpm/KakaoRouteStore.swift \
  DeliveryRouteProbe.swiftpm/BuildingEvaluation.swift \
  DeliveryRouteProbe.swiftpm/BuildingComplex.swift \
  DeliveryRouteProbe.swiftpm/BuildingLedgerClient.swift \
  DeliveryRouteProbe.swiftpm/BuildingSupplementClient.swift \
  DeliveryRouteProbe.swiftpm/BuildingReferenceStore.swift \
  DeliveryRouteProbe.swiftpm/KaptConcordance.swift \
  DeliveryRouteProbe.swiftpm/RealtyAddressSearchClient.swift \
  DeliveryRouteProbe.swiftpm/HousingModels.swift \
  DeliveryRouteProbe.swiftpm/HousingCollection.swift \
  DeliveryRouteProbe.swiftpm/HousingCollectionBackground.swift \
  DeliveryRouteProbe.swiftpm/HousingCollectionDisk.swift \
  DeliveryRouteProbe.swiftpm/RealtyRequestScheduler.swift \
  DeliveryRouteProbe.swiftpm/HousingConsolidation.swift \
  DeliveryRouteProbe.swiftpm/KaptGateway.swift \
  DeliveryRouteProbe.swiftpm/KaptHousingClient.swift \
  DeliveryRouteProbe.swiftpm/HousingAddressClient.swift \
  DeliveryRouteProbe.swiftpm/PublicDataModels.swift \
  DeliveryRouteProbe.swiftpm/PublicDataStore.swift \
  DeliveryRouteProbe.swiftpm/HousingSeed.swift \
  DeliveryRouteProbe.swiftpm/HousingIndex.swift \
  DeliveryRouteProbe.swiftpm/HousingStore.swift \
  DeliveryRouteProbe.swiftpm/RealtyHousingClient.swift \
  scripts/test_kapt_primary.swift \
  -o build/kapt-primary-tests
build/kapt-primary-tests | tee build/logs/kapt-primary.log
