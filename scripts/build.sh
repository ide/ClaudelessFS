#!/bin/bash
# Build, sign, notarize, and staple ClaudelessFS. Produces:
#   build/export/ClaudelessFS.app  — signed (and stapled unless skipped)
#   build/ClaudelessFS.zip         — release artifact containing the app
#
# Usage:
#   scripts/build.sh                  # full build + notarize + staple
#   SKIP_NOTARIZE=1 scripts/build.sh  # local build only (won't mount:
#                                     # fskitd rejects unprovisioned builds)
#
# Needs: Xcode, xcodegen (brew install xcodegen), and a notarytool keychain
# profile (default name: tuft-notarize).
set -euo pipefail

cd "$(dirname "$0")/.."

TEAM_ID="${TEAM_ID:-C8D8QTF339}"
NOTARY_PROFILE="${NOTARY_PROFILE:-tuft-notarize}"
APP="build/export/ClaudelessFS.app"

step() { printf '\n\033[1m== %s\033[0m\n' "$1"; }

step "Generate Xcode project"
xcodegen generate --quiet

step "Archive (Release, arm64)"
rm -rf build && mkdir build
xcodebuild archive \
  -project ClaudelessFS.xcodeproj -scheme ClaudelessFS -configuration Release \
  -archivePath build/ClaudelessFS.xcarchive -allowProvisioningUpdates -quiet

step "Export with Developer ID"
cat > build/exportOptions.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>developer-id</string>
	<key>teamID</key><string>${TEAM_ID}</string>
	<key>signingStyle</key><string>automatic</string>
</dict>
</plist>
EOF
xcodebuild -exportArchive \
  -archivePath build/ClaudelessFS.xcarchive -exportPath build/export \
  -exportOptionsPlist build/exportOptions.plist -allowProvisioningUpdates -quiet

# Plain `zip` on purpose: ditto zips carry AppleDouble entries that the
# `unzip` CLI extracts as literal ._ files inside the bundle, which breaks
# the code signature seal. Plain zip survives unzip, ditto, and Archive
# Utility alike.
zip_app() {
  rm -f build/ClaudelessFS.zip
  (cd build/export && zip -qry ../ClaudelessFS.zip ClaudelessFS.app)
}

if [ -z "${SKIP_NOTARIZE:-}" ]; then
  step "Notarize and staple"
  zip_app
  xcrun notarytool submit build/ClaudelessFS.zip \
    --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
fi

# Zip LAST so the release artifact contains the stapled app and Gatekeeper
# passes offline.
step "Package build/ClaudelessFS.zip"
zip_app
