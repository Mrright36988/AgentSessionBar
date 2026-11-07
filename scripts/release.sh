#!/bin/bash
# Build the release zip: AgentSessionBar.app signed ad hoc (not notarized), hook installer included.
#   release.sh <version>   ->  dist/AgentSessionBar-<version>.zip, then prints its sha256 for the cask
# Set UNIVERSAL=0 to build for arm64 only.
set -euo pipefail
cd "$(dirname "$0")/.."

version="${1:?usage: release.sh <version>}"
plist="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
[ "$version" = "$plist" ] || { echo "Resources/Info.plist says $plist; set it to $version first" >&2; exit 1; }

app=dist/AgentSessionBar.app
zip="dist/AgentSessionBar-$version.zip"
flags=(--out "$app" --adhoc)
[ "${UNIVERSAL:-1}" = 1 ] && flags+=(--universal)
mkdir -p dist
scripts/build_app.sh "${flags[@]}"
codesign --verify --deep --strict "$app"
echo "architectures: $(lipo -archs "$app/Contents/MacOS/AgentSessionBar")"
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"   # ditto keeps the signature intact; zip(1) can break it
shasum -a 256 "$zip"
