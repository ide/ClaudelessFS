#!/bin/bash
# Cut a release: set the version, build + notarize, tag, push, and publish a
# GitHub release with the notarized zip.
#
# Usage:
#   scripts/release.sh 0.0.2
#
# Run from a clean checkout of main, in sync with origin/main. The slow,
# failure-prone work (build, notarize) happens first; nothing is committed,
# tagged, or pushed until the stapled app passes Gatekeeper checks. Needs
# everything scripts/build.sh needs, plus an authenticated `gh`.
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:-}"
case "$VERSION" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) echo "Usage: scripts/release.sh <version>  (e.g. 0.0.2)" >&2; exit 1 ;;
esac
TAG="v$VERSION"
APP="build/export/ClaudelessFS.app"

step() { printf '\n\033[1m== %s\033[0m\n' "$1"; }

step "Preflight"
gh auth status --hostname github.com >/dev/null
[ -z "$(git status --porcelain)" ] || { echo "Working tree is not clean." >&2; exit 1; }
[ "$(git branch --show-current)" = main ] || { echo "Not on main." >&2; exit 1; }
git fetch origin main --tags
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || {
  echo "main is not in sync with origin/main." >&2; exit 1
}
! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || {
  echo "Tag $TAG already exists." >&2; exit 1
}

# If anything fails before the release commit lands, put project.yml back so
# a retry starts from a clean tree. After the commit this is a no-op.
trap 'git checkout --quiet -- project.yml 2>/dev/null || true' EXIT

step "Set version $VERSION"
BUILD_NUMBER=$(( $(sed -n 's/.*CURRENT_PROJECT_VERSION: "\([0-9]*\)".*/\1/p' project.yml) + 1 ))
sed -i '' \
  -e "s/MARKETING_VERSION: \"[^\"]*\"/MARKETING_VERSION: \"$VERSION\"/" \
  -e "s/CURRENT_PROJECT_VERSION: \"[0-9]*\"/CURRENT_PROJECT_VERSION: \"$BUILD_NUMBER\"/" \
  project.yml

scripts/build.sh

step "Verify notarization"
xcrun stapler validate "$APP"
spctl --assess --type execute -v "$APP"

step "Commit, tag $TAG, push"
git commit -am "Release $VERSION"
git tag -a "$TAG" -m "ClaudelessFS $VERSION"
git push origin main "$TAG"

step "Publish GitHub release"
SHA256=$(shasum -a 256 build/ClaudelessFS.zip | cut -d' ' -f1)
gh release create "$TAG" build/ClaudelessFS.zip \
  --title "ClaudelessFS $VERSION" \
  --generate-notes \
  --notes "Notarized and stapled — download, unzip, and run:

\`\`\`sh
unzip ClaudelessFS.zip
mv ClaudelessFS.app /Applications/
/Applications/ClaudelessFS.app/Contents/MacOS/ClaudelessFS setup
\`\`\`

Then: \`claudelessfs mount <directory>\`. Requires macOS 26 on Apple Silicon.

\`ClaudelessFS.zip\` SHA-256: \`$SHA256\`"

step "Done"
gh release view "$TAG" --json url -q .url
