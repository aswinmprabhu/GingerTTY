#!/usr/bin/env bash
# GingerTTY hook handler — updates tab status via AppleScript.
# Called by Claude Code hooks with the event name as $1.

EVENT="${1:-}"
TERMINAL_ID="${GINGERTTY_TERMINAL_ID:-}"
[[ -z "$TERMINAL_ID" ]] && exit 0

set_status() {
    osascript -e "tell application \"GingerTTY\" to set agent status \"$1\" on terminal id \"$TERMINAL_ID\"" &>/dev/null
}

clear_status() {
    osascript -e "tell application \"GingerTTY\" to set agent status \"\" on terminal id \"$TERMINAL_ID\"" &>/dev/null
}

case "$EVENT" in
    UserPromptSubmit)  set_status "Running" ;;
    Stop)              set_status "Done" ;;
    Notification)      set_status "Need input" ;;
    SessionEnd)        clear_status ;;
esac
