#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
DERIVED_DATA="$PROJECT_DIR/.build/ReleaseDerivedData"
BUILT_APP="$DERIVED_DATA/Build/Products/Release/Video Sampler.app"
EXTENSION="$BUILT_APP/Contents/PlugIns/VideoSamplerAU.appex"

cd "$PROJECT_DIR"

xcodebuild \
  -project VideoSampler.xcodeproj \
  -scheme "Video Sampler" \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  ARCHS='arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM= \
  build

codesign --force --sign - \
  --entitlements "$PROJECT_DIR/VideoSamplerAU/VideoSamplerAU.entitlements" \
  "$EXTENSION"
codesign --force --sign - "$BUILT_APP"
codesign --verify --deep --strict --verbose=2 "$BUILT_APP"
lipo "$BUILT_APP/Contents/MacOS/Video Sampler" -verify_arch arm64 x86_64
lipo "$EXTENSION/Contents/MacOS/VideoSamplerAU" -verify_arch arm64 x86_64

echo "Universal AUv3 build: $BUILT_APP"
echo "Signing: ad-hoc; this build is not Apple-notarized."
