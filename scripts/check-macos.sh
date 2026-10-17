#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift test --parallel
xcodegen generate
xcodebuild -project Ordnungsplaner.xcodeproj -scheme Ordnungsplaner \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
