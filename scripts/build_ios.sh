#!/bin/bash
set -euo pipefail
route_root="$(cd "$(dirname "$0")/.." && pwd)"
route_mode="${1:-check}"
if ! command -v xcodebuild >/dev/null 2>&1; then
    echo '이 빌드는 Xcode와 iOS SDK가 설치된 Mac에서 실행해야 합니다.' >&2
    exit 1
fi
case "$route_mode" in
unsigned)
    # No Apple account, certificate, appKey or provisioning profile is needed.
    mkdir -p "$route_root/build/logs" "$route_root/build/ipa"
    xcodebuild -version | tee "$route_root/build/logs/toolchain.log"
    xcrun --sdk iphoneos --show-sdk-version | tee -a "$route_root/build/logs/toolchain.log"
    xcodebuild -project "$route_root/DeliveryRouteProbe.xcodeproj" -scheme DeliveryRouteProbe -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath "$route_root/build/UnsignedDerivedData" ARCHS=arm64 ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' DEVELOPMENT_TEAM='' build 2>&1 | tee "$route_root/build/logs/unsigned-build.log"
    python3 "$route_root/scripts/package_unsigned_ipa.py" "$route_root/build/UnsignedDerivedData/Build/Products/Release-iphoneos/DeliveryRouteProbe.app" "$route_root/build/ipa"
    ;;
check)
    xcodebuild -project "$route_root/DeliveryRouteProbe.xcodeproj" -scheme DeliveryRouteProbe -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath "$route_root/build/DerivedData" CODE_SIGNING_ALLOWED=NO build
    ;;
archive)
    : "${DELIVERY_DEVELOPMENT_TEAM:?Apple 개발팀 ID를 DELIVERY_DEVELOPMENT_TEAM에 설정하세요.}"
    xcodebuild -project "$route_root/DeliveryRouteProbe.xcodeproj" -scheme DeliveryRouteProbe -configuration Release -destination 'generic/platform=iOS' -archivePath "$route_root/build/DeliveryRouteProbe.xcarchive" "DEVELOPMENT_TEAM=$DELIVERY_DEVELOPMENT_TEAM" archive
    ;;
export)
    : "${DELIVERY_EXPORT_OPTIONS:?서명·배포 방식을 정한 ExportOptions.plist 경로를 설정하세요.}"
    xcodebuild -exportArchive -archivePath "$route_root/build/DeliveryRouteProbe.xcarchive" -exportPath "$route_root/build/ipa" -exportOptionsPlist "$DELIVERY_EXPORT_OPTIONS"
    ;;
*) echo '사용법: scripts/build_ios.sh unsigned | check | archive | export' >&2; exit 2 ;;
esac
