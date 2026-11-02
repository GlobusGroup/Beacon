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
#
# App updates (Sparkle) come from the GitHub release itself: each one carries
# Beacon.dmg and an appcast.xml, and SUFeedURL in Beacon-Info.plist points at
# releases/latest/download/appcast.xml. One-time setup, the update signing
# key: once for the team, kept in the releaser's login keychain under the
# account "beacon", so it can't be confused with another app's Sparkle key.
# Generate it with Sparkle's generate_keys (in build/SourcePackages/artifacts/
# sparkle/Sparkle/bin after a build):
#   generate_keys --account beacon
# and put the public key it prints in Beacon-Info.plist as SUPublicEDKey.
# Another releaser imports the private key with
# `generate_keys --account beacon -f <file>` after the first exports it with
# `generate_keys --account beacon -x <file>`. Losing it means installed copies
# can't update; keep a backup.
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
# Outside BUILD_DIR, which each run wipes, so Sparkle isn't fetched every time.
SOURCE_PACKAGES="$PROJECT_DIR/build/SourcePackages"
SPARKLE_BIN="$SOURCE_PACKAGES/artifacts/sparkle/Sparkle/bin"
INFO_PLIST="$PROJECT_DIR/Beacon-Info.plist"
SPARKLE_ACCOUNT="beacon"

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
  # Print gh output straight to the terminal so the script ends at the prompt.
  export GH_PAGER=cat
  gh release view --repo "$REPO" "$TAG" >/dev/null 2>&1 && {
    echo "Release $TAG already exists on GitHub." >&2; exit 1; }
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 || {
    echo "Notary profile '$NOTARY_PROFILE' not found. One-time setup:" >&2
    echo "  xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <apple-id> --team-id $TEAM_ID --password <app-specific-password>" >&2
    exit 1; }

  # Installed copies only accept an update signed by the key whose public half
  # they carry, so a mismatch here would strand everyone on this version.
  xcodebuild -resolvePackageDependencies -project "$PROJECT_DIR/Beacon.xcodeproj" \
    -clonedSourcePackagesDirPath "$SOURCE_PACKAGES" -quiet
  PLIST_KEY=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$INFO_PLIST")
  KEYCHAIN_KEY=$("$SPARKLE_BIN/generate_keys" --account "$SPARKLE_ACCOUNT" -p 2>/dev/null) || {
    echo "No Sparkle signing key in your keychain. See the setup notes at the top of this script." >&2
    exit 1; }
  [ "$PLIST_KEY" = "$KEYCHAIN_KEY" ] || {
    echo "SUPublicEDKey in Beacon-Info.plist doesn't match the Sparkle key in your keychain." >&2
    echo "  plist:    $PLIST_KEY" >&2
    echo "  keychain: $KEYCHAIN_KEY" >&2
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
  -clonedSourcePackagesDirPath "$SOURCE_PACKAGES" \
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
# Sparkle's helpers do the installing, so they need the same signature.
SPARKLE_FW="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for helper in Autoupdate Updater.app XPCServices/Downloader.xpc XPCServices/Installer.xpc; do
  [ -e "$SPARKLE_FW/$helper" ] || continue
  codesign -dvv "$SPARKLE_FW/$helper" 2>&1 | grep -q "Authority=Developer ID Application" || {
    echo "Sparkle's $helper isn't Developer ID signed." >&2; exit 1; }
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

# Written before the release commit, so HEAD is still the last change in it.
if [ -z "$NOTES_FILE" ]; then
  NOTES_FILE="$BUILD_DIR/notes.md"
  LAST_TAG=$(git describe --tags --abbrev=0 HEAD 2>/dev/null || true)
  if [ -n "$LAST_TAG" ]; then
    git log --pretty='- %s' "$LAST_TAG..HEAD" > "$NOTES_FILE"
  else
    echo "Initial release." > "$NOTES_FILE"
  fi
fi

step "Sign update + write appcast"
# Signs the stapled DMG, the exact bytes installed copies will download.
ENCLOSURE_SIGNATURE=$("$SPARKLE_BIN/sign_update" --account "$SPARKLE_ACCOUNT" "$DMG")
MIN_MACOS=$(sed -n 's/.*MACOSX_DEPLOYMENT_TARGET = \([^;]*\);.*/\1/p' "$PBXPROJ" | head -1)
# Only the newest release: Sparkle needs nothing else. The DMG URL names the
# tag, so it keeps working after later releases.
cat > "$BUILD_DIR/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Beacon</title>
    <item>
      <title>Beacon $VERSION</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$NEW_BUILD_NUM</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_MACOS</sparkle:minimumSystemVersion>
      <description sparkle:format="plain-text"><![CDATA[$(sed 's/]]>/]]]]><![CDATA[>/g' "$NOTES_FILE")]]></description>
      <enclosure url="https://github.com/$REPO/releases/download/$TAG/Beacon.dmg" type="application/octet-stream" $ENCLOSURE_SIGNATURE />
    </item>
  </channel>
</rss>
XML
xmllint --noout "$BUILD_DIR/appcast.xml"

step "Commit, tag, push"
git add "$PBXPROJ" "$PATHS_SWIFT"
git commit -m "Release $VERSION"
git tag "$TAG"
git push origin HEAD "$TAG"

step "Create GitHub release"
# Upload under a stable filename so the README's
# releases/latest/download/Beacon.dmg link never needs updating. Installed
# copies find this release through its appcast.xml.
cp "$DMG" "$BUILD_DIR/Beacon.dmg"
gh release create "$TAG" "$BUILD_DIR/Beacon.dmg" "$BUILD_DIR/appcast.xml" \
  --repo "$REPO" \
  --title "Beacon $VERSION" \
  --notes-file "$NOTES_FILE"

step "Check the update feed"
# What installed copies read. Fails while the repo is private, since Sparkle
# can't sign in to GitHub.
curl -fsSL "https://github.com/$REPO/releases/latest/download/appcast.xml" \
  | grep -q "<sparkle:shortVersionString>$VERSION<" || {
  echo "The release is up, but releases/latest/download/appcast.xml doesn't serve $VERSION publicly." >&2
  exit 1; }

step "Done"
gh release view "$TAG" --repo "$REPO" --json url -q .url
