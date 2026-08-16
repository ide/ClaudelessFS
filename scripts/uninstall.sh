#!/bin/bash
# Remove ClaudelessFS: unmount everything, disable the module, delete the app.
set -euo pipefail

BUNDLE_ID="claudelessfs.FileSystemExtension"

mount | awk '/claudelessfs/ {print $3}' | while read -r mnt; do
  echo "Unmounting $mnt"
  umount "$mnt" 2>/dev/null || umount -f "$mnt" 2>/dev/null || true
done
pkill -f ClaudelessFSExtension 2>/dev/null || true

PLIST="$HOME/Library/Group Containers/group.com.apple.fskit.settings/enabledModules.plist"
if plutil -p "$PLIST" 2>/dev/null | grep -q "$BUNDLE_ID"; then
  # PlistBuddy can't delete by value, so filter with plutil + python.
  python3 - "$PLIST" "$BUNDLE_ID" <<'EOF'
import plistlib, sys
path, bundle_id = sys.argv[1], sys.argv[2]
with open(path, 'rb') as f:
    modules = plistlib.load(f)
modules = [m for m in modules if m != bundle_id]
with open(path, 'wb') as f:
    plistlib.dump(modules, f)
EOF
  echo "Disabled $BUNDLE_ID"
fi

rm -f /usr/local/bin/claudelessfs "$HOME/.local/bin/claudelessfs" 2>/dev/null || true
rm -rf /Applications/ClaudelessFS.app
sudo pkill -x fskitd || true
echo "Uninstalled."
