#!/bin/bash
# Build AgentSessionBar.app with SwiftPM (no Xcode needed). Signs with the local identity from
# make_signing_identity.sh when it exists, so macOS permission grants survive rebuilds; ad hoc otherwise.
# The hook installer and the hook go into Contents/Resources, so the app alone is enough to set up hooks.
#   build_app.sh [--out PATH] [--adhoc] [--universal]
#     --out PATH    where to put the app (default build/AgentSessionBar.app)
#     --adhoc       always sign ad hoc (release builds must not carry the local identity)
#     --universal   build for arm64 and x86_64
set -euo pipefail
cd "$(dirname "$0")/.."

app=build/AgentSessionBar.app
adhoc=0
universal=0
while [ $# -gt 0 ]; do
    case "$1" in
        --out) app="$2"; shift 2 ;;
        --adhoc) adhoc=1; shift ;;
        --universal) universal=1; shift ;;
        *) echo "usage: build_app.sh [--out PATH] [--adhoc] [--universal]" >&2; exit 2 ;;
    esac
done

if [ "$universal" = 1 ]; then
    # SwiftPM's --arch needs Xcode's xcbuild; building each triple and joining them works with the CLT alone.
    slices=()
    for arch in arm64 x86_64; do
        swift build -c release --product AgentSessionBar --triple "$arch-apple-macosx14.0"
        slices+=("$(swift build -c release --triple "$arch-apple-macosx14.0" --show-bin-path)/AgentSessionBar")
    done
    bin="$(mktemp -d)/AgentSessionBar"
    lipo -create -output "$bin" "${slices[@]}"
else
    swift build -c release --product AgentSessionBar
    bin="$(swift build -c release --show-bin-path)/AgentSessionBar"
fi

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/scripts" "$app/Contents/Resources/hook"
cp "$bin" "$app/Contents/MacOS/AgentSessionBar"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp scripts/install.py "$app/Contents/Resources/scripts/install.py"
cp hook/agentsessionbar_hook.py "$app/Contents/Resources/hook/agentsessionbar_hook.py"

signing="$HOME/Library/Application Support/AgentSessionBar/signing"
keychain="$signing/agentsessionbar-signing.keychain-db"
if [ "$adhoc" = 0 ] && [ -f "$keychain" ]; then
    security unlock-keychain -p "$(cat "$signing/keychain-password")" "$keychain"
    identity="$(security find-identity -p codesigning "$keychain" | awk '/AgentSessionBar Local Signing/ {print $2; exit}')"
    # codesign refuses the identity until its certificate is trusted for code signing (a one-time user step).
    codesign --force --keychain "$keychain" --sign "$identity" "$app" 2>/dev/null \
        || { echo "local identity not trusted yet; signing ad hoc" >&2; codesign --force --sign - "$app"; }
else
    codesign --force --sign - "$app"
fi
echo "$app"
