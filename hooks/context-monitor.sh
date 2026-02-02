#!/bin/bash
# Context Monitor - Check usage and warn when approaching limits
#
# Uses direct session file lookup instead of find for speed and accuracy.
# The wrapper writes current session info to ~/.claude/.current-session

SESSION_DIR="$HOME/.claude/projects"
STATUS_FILE="$HOME/.claude/.context-status"
TEST_MODE_FILE="$HOME/.claude/.test-mode"
CURRENT_SESSION_FILE="$HOME/.claude/.current-session"

# Fast lookup: use session file if available (written by wrapper)
if [ -f "$CURRENT_SESSION_FILE" ]; then
    CURRENT_TRANSCRIPT=$(cut -d: -f2 "$CURRENT_SESSION_FILE" 2>/dev/null)
    SESSION_ID=$(cut -d: -f1 "$CURRENT_SESSION_FILE" 2>/dev/null)
fi

# Fallback to find if session file doesn't exist or transcript gone
if [ -z "$CURRENT_TRANSCRIPT" ] || [ ! -f "$CURRENT_TRANSCRIPT" ]; then
    CURRENT_TRANSCRIPT=$(find "$SESSION_DIR" -maxdepth 2 -name "*.jsonl" -mmin -60 -type f 2>/dev/null | \
        grep -v "/subagents/" | \
        xargs -r ls -t 2>/dev/null | \
        head -1)
    # Extract session ID from filename if we had to fall back
    [ -n "$CURRENT_TRANSCRIPT" ] && SESSION_ID=$(basename "$CURRENT_TRANSCRIPT" .jsonl)
fi

[ -z "$CURRENT_TRANSCRIPT" ] && exit 0
[ ! -f "$CURRENT_TRANSCRIPT" ] && exit 0

SIZE_BYTES=$(stat -c %s "$CURRENT_TRANSCRIPT" 2>/dev/null)
[ -z "$SIZE_BYTES" ] && exit 0

SIZE_KB=$((SIZE_BYTES / 1024))

# Display format
if [ "$SIZE_BYTES" -ge 1048576 ]; then
    SIZE_DISPLAY=$(awk "BEGIN {printf \"%.1fMB\", $SIZE_BYTES / 1048576}")
else
    SIZE_DISPLAY="${SIZE_KB}KB"
fi

# Thresholds
if [ -f "$TEST_MODE_FILE" ]; then
    # Ultra-low for testing - triggers almost immediately
    EARLY_WARN_KB=5
    WARN_KB=10
    CRITICAL_KB=15
else
    # Based on actual limit testing (2026-02-02): 100% = ~1966KB
    # Setting conservative thresholds with safety margin
    EARLY_WARN_KB=1300
    WARN_KB=1500
    CRITICAL_KB=1700
fi

if [ "$SIZE_KB" -ge "$CRITICAL_KB" ]; then
    echo "CRITICAL:${SIZE_DISPLAY}" > "$STATUS_FILE"

    # Auto-trigger handoff and restart when CRITICAL
    # Use session-specific lock to only trigger once per session
    TRIGGER_LOCK="$HOME/.claude/.critical-triggered-${SESSION_ID}"

    if [ ! -f "$TRIGGER_LOCK" ]; then
        touch "$TRIGGER_LOCK"
        # Create handoff file
        bash "$HOME/.claude/hooks/pre-compact-handoff.sh" 2>/dev/null
        # Signal wrapper to restart - include session ID for verification
        echo "${SESSION_ID}:${PWD}" > "$HOME/.claude/.restart-session"
    fi

elif [ "$SIZE_KB" -ge "$WARN_KB" ]; then
    echo "WARN:${SIZE_DISPLAY}" > "$STATUS_FILE"
elif [ "$SIZE_KB" -ge "$EARLY_WARN_KB" ]; then
    echo "EARLY_WARN:${SIZE_DISPLAY}" > "$STATUS_FILE"
else
    echo "OK:${SIZE_DISPLAY}" > "$STATUS_FILE"
fi

exit 0
