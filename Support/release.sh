#!/bin/sh
# Cuts a release: builds and signs Caskroom.app, notarises it, publishes
# Caskroom-<version>.zip as a GitHub Release and points the tap's cask at it.
#
#     SIGN="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=caskroom Support/release.sh 0.2.0
#
# NOTARY_PROFILE is a keychain profile made once with
# `xcrun notarytool store-credentials`.
#
#     Support/release.sh --dry-run 0.2.0
#
# stops before publishing: it signs with SIGN if set (ad-hoc otherwise),
# notarises only if NOTARY_PROFILE is set, and leaves the zip and the cask in
# build/.
set -eu

REPO=vs-cristian/caskroom
TAP=vs-cristian/homebrew-tap

dry_run=
if [ "${1:-}" = "--dry-run" ]; then dry_run=1; shift; fi
version=${1:?usage: Support/release.sh [--dry-run] <version>}
tag="v$version"
zip="build/Caskroom-$version.zip"
cask=build/caskroom.rb

cd "$(dirname "$0")/.."

if [ -z "$dry_run" ]; then
    # An ad-hoc signed download is blocked by Gatekeeper, so never publish one.
    : "${SIGN:?set SIGN to a Developer ID Application identity}"
    : "${NOTARY_PROFILE:?set NOTARY_PROFILE to a notarytool keychain profile}"
    [ -z "$(git status --porcelain)" ] || { echo "uncommitted changes" >&2; exit 1; }
    [ "$(git rev-parse HEAD)" = "$(git rev-parse '@{upstream}')" ] || { echo "HEAD isn't pushed" >&2; exit 1; }
    if gh release view "$tag" --repo "$REPO" >/dev/null 2>&1; then echo "$tag already released" >&2; exit 1; fi
fi

make app VERSION="$version" SIGN="${SIGN:--}"
rm -f "$zip"
ditto -c -k --keepParent build/Caskroom.app "$zip"

if [ -n "${NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$zip" --keychain-profile "$NOTARY_PROFILE" --wait
    # The ticket is stapled to the app, so the zip is made again around it.
    xcrun stapler staple build/Caskroom.app
    rm "$zip"
    ditto -c -k --keepParent build/Caskroom.app "$zip"
fi

sha=$(shasum -a 256 "$zip" | cut -d' ' -f1)
cat > "$cask" <<EOF
cask "caskroom" do
  version "$version"
  sha256 "$sha"

  url "https://github.com/$REPO/releases/download/v#{version}/Caskroom-#{version}.zip"
  name "Caskroom"
  desc "GUI for Homebrew"
  homepage "https://github.com/$REPO"

  depends_on arch: :arm64
  depends_on macos: :sequoia

  app "Caskroom.app"

  zap trash: [
    "~/Library/Application Support/io.github.vs-cristian.caskroom",
    "~/Library/Caches/io.github.vs-cristian.caskroom",
    "~/Library/HTTPStorages/io.github.vs-cristian.caskroom",
    "~/Library/Preferences/io.github.vs-cristian.caskroom.plist",
  ]
end
EOF

if [ -n "$dry_run" ]; then
    echo "dry run: $zip and $cask are ready, nothing published"
    exit 0
fi

gh release create "$tag" "$zip" --repo "$REPO" --target "$(git rev-parse HEAD)" \
    --title "Caskroom $version" --generate-notes

tap=$(mktemp -d)
trap 'rm -rf "$tap"' EXIT
gh repo clone "$TAP" "$tap" -- --quiet --depth 1
mkdir -p "$tap/Casks"
cp "$cask" "$tap/Casks/caskroom.rb"
git -C "$tap" add Casks/caskroom.rb
git -C "$tap" -c user.email="$(git config user.email)" commit --quiet -m "caskroom $version"
git -C "$tap" push --quiet
echo "released $tag: brew install --cask ${TAP%/homebrew-tap}/tap/caskroom"
