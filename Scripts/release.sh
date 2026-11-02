#!/bin/bash
# One-command release for Beacon: archive, export, DMG, notarize, tag,
# GitHub release, with the version as the single source of truth.
#
# Usage: Scripts/release.sh <version> [--dry-run] [--notes-file <path>]
#
#   Scripts/release.sh 1.1.0              # full release
#   Scripts/release.sh 1.1.0 --dry-run    # build + signed DMG only; no notarize,
#                                         # no tag/push/release, no commits
#
# One-time setup (once per machine, for notarization). The credentials are
# per team, so the profile Skillet's release uses works here too:
#   xcrun notarytool store-credentials skillet-notary \
#     --apple-id <your-apple-id> --team-id DQQ2V9BUW7 \
#     --password <app-specific-password from appleid.apple.com>
# Set BEACON_NOTARY_PROFILE to use a differently named profile.
#
# Signing uses the team's Developer ID (DQQ2V9BUW7) via automatic signing and
# -allowProvisioningUpdates.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="$PROJECT_DIR/Scripts"
PBXPROJ="$PROJECT_DIR/Beacon.xcodeproj/project.pbxproj"
# The daemon and CLI report this version; keep it in step with the app's.
PATHS_SWIFT="$PROJECT_DIR/Beacon/Shared/BeaconPaths.swift"
TEAM_ID="DQQ2V9BUW7"
NOTARY_PROFILE="${BEACON_NOTARY_PROFILE:-skillet-notary}"
REPO="GlobusGroup/Beacon"
BUILD_DIR="$PROJECT_DIR/build/release"

VERSION="${1:?Usage: release.sh <version> [--dry-run] [--notes-file <path>]}"
shift
DRY_RUN=0
NOTES_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --notes-file) NOTES_FILE="${2:?--notes-file needs a path}"; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || {
  echo "Version must look like 1.2 or 1.2.0 (got: $VERSION)" >&2; exit 1; }
TAG="v$VERSION"
DMG="$BUILD_DIR/Beacon-$VERSION.dmg"

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

step "Preflight"
cd "$PROJECT_DIR"
command -v create-dmg >/dev/null || { echo "create-dmg not installed (brew install create-dmg)" >&2; exit 1; }
if [ "$DRY_RUN" -eq 0 ]; then
  [ -z "$(git status --porcelain --untracked-files=no)" ] || {
    echo "Working tree not clean; commit or stash first." >&2; exit 1; }
  ! git rev-parse "$TAG" >/dev/null 2>&1 || {
    echo "Tag $TAG already exists." >&2; exit 1; }
  # gh keychain tokens are often unreadable in scripted shells; export explicitly.
  export GH_TOKEN=$(gh auth token)
  gh release view --repo "$REPO" "$TAG" >/dev/null 2>&1 && {
    echo "Release $TAG already exists on GitHub." >&2; exit 1; }
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 || {
    echo "Notary profile '$NOTARY_PROFILE' not found. One-time setup:" >&2
    echo "  xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <apple-id> --team-id $TEAM_ID --password <app-specific-password>" >&2
    exit 1; }
fi

step "Set version $VERSION in project"
BUILD_NUM=$(sed -n 's/.*CURRENT_PROJECT_VERSION = \([0-9]*\);.*/\1/p' "$PBXPROJ" | head -1)
NEW_BUILD_NUM=$((BUILD_NUM + 1))
sed -i '' \
  -e "s/MARKETING_VERSION = [^;]*;/MARKETING_VERSION = $VERSION;/g" \
  -e "s/CURRENT_PROJECT_VERSION = [^;]*;/CURRENT_PROJECT_VERSION = $NEW_BUILD_NUM;/g" \
  "$PBXPROJ"
sed -i '' -e "s/static let version = \"[^\"]*\"/static let version = \"$VERSION\"/" "$PATHS_SWIFT"
grep -q "static let version = \"$VERSION\"" "$PATHS_SWIFT" || {
  echo "Couldn't set the version in $PATHS_SWIFT" >&2; exit 1; }
echo "Marketing version $VERSION, build $NEW_BUILD_NUM"

step "Archive (Release)"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
ARCHIVE="$BUILD_DIR/Beacon.xcarchive"
xcodebuild archive \
  -project "$PROJECT_DIR/Beacon.xcodeproj" \
  -scheme Beacon \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  -quiet

step "Export Developer ID-signed app"
cat > "$BUILD_DIR/exportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>destination</key><string>export</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>$TEAM_ID</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$BUILD_DIR/exportOptions.plist" \
  -exportPath "$BUILD_DIR/export" \
  -allowProvisioningUpdates \
  -quiet
APP="$BUILD_DIR/export/Beacon.app"
codesign --verify --deep --strict "$APP"
codesign -dv "$APP" 2>&1 | grep TeamIdentifier
# The daemon and CLI are installed out of the bundle and run on their own, so
# each must carry a Developer ID signature, hardened runtime and a secure
# timestamp, or notarization rejects the app.
for tool in beacond beacon; do
  info=$(codesign -dvv "$APP/Contents/Helpers/$tool" 2>&1)
  grep -q "Authority=Developer ID Application" <<<"$info" \
    && grep -q "^Timestamp=" <<<"$info" \
    && grep -q "flags=.*runtime" <<<"$info" || {
    echo "Contents/Helpers/$tool isn't Developer ID signed with a timestamp and hardened runtime:" >&2
    echo "$info" >&2
    exit 1; }
done

step "Build DMG"
"$SCRIPT_DIR/make-dmg.sh" "$APP" "$DMG"

if [ "$DRY_RUN" -eq 1 ]; then
  step "Dry run complete"
  echo "Built (not notarized, not released): $DMG"
  echo "Version changes left uncommitted; 'git checkout $PBXPROJ $PATHS_SWIFT' to discard."
  exit 0
fi

step "Notarize + staple DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"

step "Commit, tag, push"
git add "$PBXPROJ" "$PATHS_SWIFT"
git commit -m "Release $VERSION"
git tag "$TAG"
git push origin HEAD "$TAG"

step "Create GitHub release"
if [ -z "$NOTES_FILE" ]; then
  NOTES_FILE="$BUILD_DIR/notes.md"
  LAST_TAG=$(git describe --tags --abbrev=0 "$TAG^" 2>/dev/null || true)
  if [ -n "$LAST_TAG" ]; then
    git log --pretty='- %s' "$LAST_TAG..$TAG^" > "$NOTES_FILE"
  else
    echo "Initial release." > "$NOTES_FILE"
  fi
fi
# Upload under a stable filename so the README's
# releases/latest/download/Beacon.dmg link never needs updating.
cp "$DMG" "$BUILD_DIR/Beacon.dmg"
gh release create "$TAG" "$BUILD_DIR/Beacon.dmg" \
  --repo "$REPO" \
  --title "Beacon $VERSION" \
  --notes-file "$NOTES_FILE"

step "Done"
gh release view "$TAG" --repo "$REPO" --json url -q .url
