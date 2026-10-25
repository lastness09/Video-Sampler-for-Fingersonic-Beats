#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
OUTPUT_PATH="${TMPDIR:-/tmp}/video_sampler_dsp_smoke"

xcrun clang++ \
  -std=c++20 \
  -x objective-c++ \
  "$PROJECT_DIR/Tests/DSPKernelSmokeTest.mm" \
  -framework AudioToolbox \
  -framework CoreMIDI \
  -o "$OUTPUT_PATH"

"$OUTPUT_PATH"
