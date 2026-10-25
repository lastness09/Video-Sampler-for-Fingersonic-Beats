#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
TEST_VIDEO="${TMPDIR:-/tmp}/video_sampler_decode_test.mp4"
TEST_BINARY="${TMPDIR:-/tmp}/video_sampler_decode_test"
MODULE_CACHE="$PROJECT_DIR/.build/SwiftModuleCache"

mkdir -p "$MODULE_CACHE"

ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i "color=c=0x18202b:s=320x180:r=30" \
  -f lavfi -i "sine=frequency=440:sample_rate=48000" \
  -t 0.3 -c:v h264 -pix_fmt yuv420p -c:a aac -ac 2 -shortest \
  "$TEST_VIDEO"

xcrun swiftc \
  -parse-as-library \
  "$PROJECT_DIR/VideoSamplerAU/Audio/VideoClipLoader.swift" \
  "$PROJECT_DIR/Tests/VideoClipLoaderSmoke.swift" \
  -module-cache-path "$MODULE_CACHE" \
  -framework AVFoundation \
  -framework CoreMedia \
  -o "$TEST_BINARY"

"$TEST_BINARY" "$TEST_VIDEO"
