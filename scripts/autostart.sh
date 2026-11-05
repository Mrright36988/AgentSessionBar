#!/bin/bash
# Start AgentDeck at login and bring it back if it crashes, with a per-user LaunchAgent.
# Quitting from the app's menu exits cleanly and stays quit. It shows up in
# System Settings > General > Login Items, where it can also be switched off.
#   autostart.sh on | off | status
set -euo pipefail

label=local.agent-deck
plist="$HOME/Library/LaunchAgents/$label.plist"
app="$(cd "$(dirname "$0")/.." && pwd)/build/AgentDeck.app"
domain="gui/$(id -u)"
logs="$HOME/Library/Application Support/agent-deck"

case "${1:-status}" in
on)
    [ -x "$app/Contents/MacOS/AgentDeck" ] || { echo "build the app first: scripts/build_app.sh" >&2; exit 1; }
    mkdir -p "$(dirname "$plist")" "$logs"
    cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$label</string>
    <key>ProgramArguments</key>
    <array>
        <string>$app/Contents/MacOS/AgentDeck</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardErrorPath</key>
    <string>$logs/launchd.err</string>
</dict>
</plist>
EOF
    launchctl bootout "$domain/$label" 2>/dev/null || true
    pkill -x AgentDeck || true   # the copy started by hand; launchd starts the supervised one
    launchctl bootstrap "$domain" "$plist"
    echo "autostart on ($plist)"
    ;;
off)
    launchctl bootout "$domain/$label" 2>/dev/null || true
    rm -f "$plist"
    echo "autostart off (the app keeps running until you quit it)"
    ;;
status)
    if launchctl print "$domain/$label" >/dev/null 2>&1; then
        launchctl print "$domain/$label" | grep -E "^\s*(state|pid|last exit code)" | sed 's/^\s*/  /'
        echo "autostart: on"
    else
        echo "autostart: off"
    fi
    ;;
*)
    echo "usage: autostart.sh on | off | status" >&2
    exit 2
    ;;
esac
