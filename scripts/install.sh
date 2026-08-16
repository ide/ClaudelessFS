#!/bin/bash
# Build, notarize, install, and enable ClaudelessFS. One command, no prompts.
#
# Usage:
#   scripts/install.sh                  # full pipeline
#   SKIP_NOTARIZE=1 scripts/install.sh  # local build only (won't mount:
#                                       # fskitd rejects unprovisioned builds)
#
# Needs: Xcode, xcodegen (brew install xcodegen), a notarytool keychain
# profile (default name: tuft-notarize), and sudo rights to restart fskitd.
set -euo pipefail

cd "$(dirname "$0")/.."

TEAM_ID="${TEAM_ID:-C8D8QTF339}"
NOTARY_PROFILE="${NOTARY_PROFILE:-tuft-notarize}"
BUNDLE_ID="claudelessfs.FileSystemExtension"
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

if [ -z "${SKIP_NOTARIZE:-}" ]; then
  step "Notarize and staple"
  # Plain `zip` on purpose: ditto zips carry AppleDouble entries that the
  # `unzip` CLI extracts as literal ._ files inside the bundle, which breaks
  # the code signature seal. Plain zip survives unzip, ditto, and Archive
  # Utility alike.
  rm -f build/ClaudelessFS.zip
  (cd build/export && zip -qry ../ClaudelessFS.zip ClaudelessFS.app)
  xcrun notarytool submit build/ClaudelessFS.zip \
    --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  # Re-zip AFTER stapling: the release zip must contain the ticket so
  # Gatekeeper passes offline.
  rm -f build/ClaudelessFS.zip
  (cd build/export && zip -qry ../ClaudelessFS.zip ClaudelessFS.app)
fi

step "Install to /Applications"
# Unmount any live mounts first so the old extension lets go.
mount | awk '/claudelessfs/ {print $3}' | while read -r mnt; do
  umount "$mnt" 2>/dev/null || umount -f "$mnt" 2>/dev/null || true
done
rm -rf /Applications/ClaudelessFS.app
cp -R "$APP" /Applications/
# Register the bundle (and its extension) without launching anything.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f /Applications/ClaudelessFS.app

step "Set up (PATH link + enable module)"
CLI=/Applications/ClaudelessFS.app/Contents/MacOS/ClaudelessFS
"$CLI" setup

step "Done"
"$CLI" status
