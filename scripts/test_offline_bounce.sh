#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/video-sampler-offline.XXXXXX")"

ffmpeg -hide_banner -loglevel error \
  -f lavfi -i "color=c=0x18202b:s=160x90:r=30" \
  -f lavfi -i "sine=frequency=440:sample_rate=48000" \
  -t 0.5 -c:v h264 -pix_fmt yuv420p -c:a aac -ac 2 -shortest \
  "$TEST_DIR/fixture.mov"

xcrun clang++ -std=c++20 -fobjc-arc -fblocks -c \
  "$PROJECT_DIR/VideoSamplerAU/DSP/VideoSamplerDSPBridge.mm" \
  -o "$TEST_DIR/bridge.o"

xcrun swiftc -parse-as-library -O \
  -import-objc-header "$PROJECT_DIR/VideoSamplerAU/DSP/VideoSamplerAU-Bridging-Header.h" \
  -cxx-interoperability-mode=default -Xcc -std=c++20 \
  -module-cache-path "$TEST_DIR/ModuleCache" \
  "$PROJECT_DIR/VideoSamplerAU/Shared/PadState.swift" \
  "$PROJECT_DIR/VideoSamplerAU/Audio/VideoClipLoader.swift" \
  "$PROJECT_DIR/VideoSamplerAU/Audio/VideoSamplerAudioUnit.swift" \
  "$PROJECT_DIR/VideoSamplerAU/UI/VideoSamplerViewModel.swift" \
  "$PROJECT_DIR/VideoSamplerAU/UI/VideoSamplerMainView.swift" \
  "$PROJECT_DIR/VideoSamplerAU/UI/AudioUnitViewController.swift" \
  "$PROJECT_DIR/Tests/OfflineBounceRegression.swift" \
  "$TEST_DIR/bridge.o" \
  -framework AVFoundation -framework AudioToolbox -framework CoreMIDI -framework AppKit \
  -framework AVKit -framework CoreAudioKit -framework SwiftUI \
  -o "$TEST_DIR/offline-regression"

"$TEST_DIR/offline-regression" "$TEST_DIR/fixture.mov"
"$TEST_DIR/offline-regression" "$TEST_DIR/fixture.mov" --restore
