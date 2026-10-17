#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild -project Ordnungsplaner.xcodeproj -scheme Ordnungsplaner \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath DerivedDataDevice CODE_SIGNING_ALLOWED=NO build
mkdir -p build/Payload
cp -R DerivedDataDevice/Build/Products/Debug-iphoneos/Ordnungsplaner.app build/Payload/
(cd build && /usr/bin/zip -qry Ordnungsplaner-unsigniert.ipa Payload)
