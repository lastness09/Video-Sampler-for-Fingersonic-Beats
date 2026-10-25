#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
DERIVED_DATA="$PROJECT_DIR/.build/ReleaseDerivedData"
BUILT_APP="$DERIVED_DATA/Build/Products/Release/Video Sampler.app"
INSTALLED_APP="/Applications/Video Sampler.app"
zsh "$PROJECT_DIR/scripts/build_release.sh"

ditto "$BUILT_APP" "$INSTALLED_APP"
pluginkit -a "$INSTALLED_APP/Contents/PlugIns/VideoSamplerAU.appex"

echo "Installed: $INSTALLED_APP"
echo "The app is only the required AUv3 container; there is no standalone workflow."
echo "Logic: AU Instruments > Fingersonic > Video Sampler"
