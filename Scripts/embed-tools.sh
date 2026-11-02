#!/bin/sh
# Xcode build phase: builds the daemon and CLI with SwiftPM and embeds them,
# signed, inside the app bundle. The app's Install button copies
# them from there, so a fresh Mac needs nothing but Beacon.app.
set -eu

# Xcode exports SDK and toolchain variables that confuse a nested SwiftPM
# build, so run it with a clean environment.
env -i PATH="/usr/bin:/bin:/usr/sbin:/sbin" HOME="$HOME" DEVELOPER_DIR="$DEVELOPER_DIR" \
    /usr/bin/xcrun swift build -c release --package-path "$SRCROOT"

# Contents/Helpers, not Contents/MacOS: the app's executable is "Beacon" and
# APFS is usually case-insensitive, so copying "beacon" into Contents/MacOS
# would overwrite the app itself.
DEST="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
mkdir -p "$DEST"
for tool in beacond beacon; do
    cp -f "$SRCROOT/.build/release/$tool" "$DEST/$tool"
    # Sign with the app's identity so the bundle seals cleanly and the
    # installed daemon carries a real signature, not SwiftPM's ad-hoc one.
    # Archives (ACTION=install) get a secure timestamp, which notarization
    # requires; everyday builds skip it to stay offline and fast.
    if [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ] && [ "$EXPANDED_CODE_SIGN_IDENTITY" != "-" ]; then
        if [ "${ACTION:-build}" = "install" ]; then timestamp=--timestamp; else timestamp=--timestamp=none; fi
        /usr/bin/codesign --force --options runtime "$timestamp" \
            --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$DEST/$tool"
    fi
done
