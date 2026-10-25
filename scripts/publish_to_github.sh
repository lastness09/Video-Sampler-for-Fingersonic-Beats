#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
OWNER="lastness09"
REPOSITORY="Video-Sampler-for-Fingersonic-Beats"
TARGET="$OWNER/$REPOSITORY"
cd "$PROJECT_DIR"

if command -v gh >/dev/null 2>&1; then
  GH_BIN="$(command -v gh)"
elif [[ -x "$PROJECT_DIR/.build/github-cli/bin/gh" ]]; then
  GH_BIN="$PROJECT_DIR/.build/github-cli/bin/gh"
else
  print -u2 "GitHub CLI is required. Install it from https://cli.github.com and run this script again."
  exit 1
fi

if ! "$GH_BIN" auth status --hostname github.com >/dev/null 2>&1; then
  print "Complete GitHub CLI sign-in using the lastness09 account."
  "$GH_BIN" auth login --hostname github.com --git-protocol https --web
fi
LOGIN="$("$GH_BIN" api user --jq .login)"
if [[ "$LOGIN" != "$OWNER" ]]; then
  "$GH_BIN" auth switch --hostname github.com --user "$OWNER"
  LOGIN="$("$GH_BIN" api user --jq .login)"
fi
if [[ "$LOGIN" != "$OWNER" ]]; then
  print -u2 "Publication stopped: the authenticated GitHub account must be lastness09."
  exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
  print -u2 "Commit the intended source changes before publishing."
  exit 1
fi
if [[ "$(git branch --show-current)" != "main" ]]; then
  print -u2 "Publication requires the prepared main branch."
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' VideoSamplerHost/Info.plist)"
TAG="v$VERSION"
RELEASE_DIR="$PROJECT_DIR/dist/VideoSampler-$VERSION-macOS"
for name in "VideoSampler-$VERSION-AUv3-macOS.zip" "VideoSampler-$VERSION-Source.zip" "VideoSampler-$VERSION-Complete.zip" SHA256SUMS.txt INSTALL_AND_USER_GUIDE.html INSTALL_AND_USER_GUIDE.txt VERIFICATION.txt RELEASE_NOTES.md RELEASE_POST.txt; do
  if [[ ! -f "$RELEASE_DIR/$name" ]]; then
    print -u2 "Missing release file: $name. Create the release packages first."
    exit 1
  fi
done
(cd "$RELEASE_DIR" && shasum -a 256 -c SHA256SUMS.txt)

if "$GH_BIN" repo view "$TARGET" --json name >/dev/null 2>&1; then
  if [[ "$("$GH_BIN" repo view "$TARGET" --json isPrivate --jq .isPrivate)" != "false" ]]; then
    print -u2 "Publication stopped: an existing private repository will not be made public by this script."
    exit 1
  fi
else
  "$GH_BIN" repo create "$TARGET" --public \
    --description "A macOS AUv3 video sampler for Fingersonic Beats. Trigger local video clips and their audio with MIDI in Logic Pro."
fi

REMOTE_URL="https://github.com/$TARGET.git"
if git remote get-url origin >/dev/null 2>&1; then
  EXISTING_REMOTE="$(git remote get-url origin)"
  if [[ "$EXISTING_REMOTE" != "$REMOTE_URL" && "$EXISTING_REMOTE" != "git@github.com:$TARGET.git" ]]; then
    print -u2 "Publication stopped: origin points to another repository."
    exit 1
  fi
else
  git remote add origin "$REMOTE_URL"
fi
if git show-ref --verify --quiet "refs/tags/$TAG"; then
  if [[ "$(git rev-parse "$TAG^{commit}")" != "$(git rev-parse HEAD)" ]]; then
    print -u2 "Publication stopped: the release tag points to a different commit."
    exit 1
  fi
else
  git tag -a "$TAG" -m "Video Sampler $VERSION macOS AUv3 test release"
fi

# Configure the credential helper for this repository only.
git config --local credential.https://github.com.helper ''
git config --local --add credential.https://github.com.helper "!\"$GH_BIN\" auth git-credential"
git push --set-upstream origin main
git push origin "$TAG"

NOTES="$PROJECT_DIR/.build/github-release-notes.md"
mkdir -p "$PROJECT_DIR/.build"
cat > "$NOTES" <<EOF
Video Sampler for Fingersonic Beats is a macOS AUv3 instrument for playing video clips and their audio with MIDI in Logic Pro.

### Downloads

- **VideoSampler-$VERSION-AUv3-macOS.zip**: ready-to-use plug-in container app and English user guide.
- **VideoSampler-$VERSION-Source.zip**: Xcode project, source, tests, and scripts.
- **VideoSampler-$VERSION-Complete.zip**: app, source, documentation, and publishing material together.
- **SHA256SUMS.txt**: checksums for the three ZIP downloads.

### Installation

Requires macOS 13.0 or later. Apple Silicon and Intel binaries are included. Keep the complete Video Sampler.app in Applications, then load AU Instruments → Fingersonic → Video Sampler → Stereo in Logic's Instrument slot.

This is an ad-hoc-signed test build without Apple notarization. First-launch approval may be required under System Settings → Privacy & Security → Open Anyway. See the included English guide for complete steps and troubleshooting.

### Changes and verification

Includes the Fingersonic family app icon and the corrected Logic Pro / Logic Pro Creator Studio launcher. AU validation, DSP regression, video-audio decoding, offline bounce, and project-state restoration passed on the documented Apple Silicon test system. See VERIFICATION.txt for actual coverage and limitations.
EOF

if ! "$GH_BIN" release view "$TAG" --repo "$TARGET" >/dev/null 2>&1; then
  "$GH_BIN" release create "$TAG" --repo "$TARGET" --draft --prerelease --verify-tag \
    --title "Video Sampler $VERSION — macOS AUv3 test build" --notes-file "$NOTES"
fi
"$GH_BIN" release upload "$TAG" --repo "$TARGET" --clobber \
  "$RELEASE_DIR/VideoSampler-$VERSION-AUv3-macOS.zip" \
  "$RELEASE_DIR/VideoSampler-$VERSION-Source.zip" \
  "$RELEASE_DIR/VideoSampler-$VERSION-Complete.zip" \
  "$RELEASE_DIR/SHA256SUMS.txt" \
  "$RELEASE_DIR/INSTALL_AND_USER_GUIDE.html" \
  "$RELEASE_DIR/INSTALL_AND_USER_GUIDE.txt" \
  "$RELEASE_DIR/VERIFICATION.txt" \
  "$RELEASE_DIR/RELEASE_NOTES.md" \
  "$RELEASE_DIR/RELEASE_POST.txt"
"$GH_BIN" release edit "$TAG" --repo "$TARGET" --draft=false --prerelease --notes-file "$NOTES"
"$GH_BIN" release view "$TAG" --repo "$TARGET" --json url,isDraft,assets
print "Published: https://github.com/$TARGET"
