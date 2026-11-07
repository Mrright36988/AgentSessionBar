#!/bin/bash
# Start AgentSessionBar at login and bring it back if it crashes, with a per-user LaunchAgent.
# Quitting from the app's menu exits cleanly and stays quit. It shows up in
# System Settings > General > Login Items, where it can also be switched off.
#   autostart.sh on | off | status
set -euo pipefail

label=local.agentsessionbar
plist="$HOME/Library/LaunchAgents/$label.plist"
app="$(cd "$(dirname "$0")/.." && pwd)/build/AgentSessionBar.app"
domain="gui/$(id -u)"
logs="$HOME/Library/Application Support/AgentSessionBar"
# The LaunchAgent from before the rename (agent-deck, until 2026-11-07). on and off both remove it,
# and quit the old app, so it cannot come back at the next login.
legacy=local.agent-deck

drop_legacy() {
    launchctl bootout "$domain/$legacy" 2>/dev/null || true
    rm -f "$HOME/Library/LaunchAgents/$legacy.plist"
    pkill -x AgentDeck || true
}

case "${1:-status}" in
on)
    [ -x "$app/Contents/MacOS/AgentSessionBar" ] || { echo "build the app first: scripts/build_app.sh" >&2; exit 1; }
    drop_legacy
    mkdir -p "$(dirname "$plist")" "$logs"
    cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$label</string>
    <key>ProgramArguments</key>
    <array>
        <string>$app/Contents/MacOS/AgentSessionBar</string>
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
PLIST
    launchctl bootout "$domain/$label" 2>/dev/null || true
    pkill -x AgentSessionBar || true   # the copy started by hand; launchd starts the supervised one
    launchctl bootstrap "$domain" "$plist"
    echo "autostart on ($plist)"
    ;;
off)
    launchctl bootout "$domain/$label" 2>/dev/null || true
    rm -f "$plist"
    drop_legacy
    echo "autostart off (the app keeps running until you quit it)"
    ;;
status)
    if launchctl print "$domain/$label" >/dev/null 2>&1; then
        launchctl print "$domain/$label" | grep -E "^\s*(state|pid|last exit code)" | sed 's/^\s*/  /'
        echo "autostart: on"
    else
        echo "autostart: off"
    fi
    if launchctl print "$domain/$legacy" >/dev/null 2>&1 || [ -f "$HOME/Library/LaunchAgents/$legacy.plist" ]; then
        echo "the old agent-deck LaunchAgent is still installed: run autostart.sh on (or off) to remove it"
    fi
    ;;
*)
    echo "usage: autostart.sh on | off | status" >&2
    exit 2
    ;;
esac
