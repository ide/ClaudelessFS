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

APP="build/export/ClaudelessFS.app"

step() { printf '\n\033[1m== %s\033[0m\n' "$1"; }

scripts/build.sh

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
