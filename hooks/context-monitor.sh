#!/bin/bash
# Context Monitor - Check usage and warn when approaching limits

SESSION_DIR="$HOME/.claude/projects"
STATUS_FILE="$HOME/.claude/.context-status"
TEST_MODE_FILE="$HOME/.claude/.test-mode"

# Find main session transcript (not subagent files)
CURRENT_TRANSCRIPT=$(find "$SESSION_DIR" -maxdepth 2 -name "*.jsonl" -mmin -60 -type f 2>/dev/null | \
    grep -v "/subagents/" | \
    xargs -r ls -t 2>/dev/null | \
    head -1)

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
    # Based on actual compact trigger at 1390KB (2026-02-02)
    EARLY_WARN_KB=800
    WARN_KB=1024
    CRITICAL_KB=1200
fi

if [ "$SIZE_KB" -ge "$CRITICAL_KB" ]; then
    echo "CRITICAL:${SIZE_DISPLAY}" > "$STATUS_FILE"
elif [ "$SIZE_KB" -ge "$WARN_KB" ]; then
    echo "WARN:${SIZE_DISPLAY}" > "$STATUS_FILE"
elif [ "$SIZE_KB" -ge "$EARLY_WARN_KB" ]; then
    echo "EARLY_WARN:${SIZE_DISPLAY}" > "$STATUS_FILE"
else
    echo "OK:${SIZE_DISPLAY}" > "$STATUS_FILE"
fi

# Silent exit - Claude checks status file periodically per CLAUDE.md instructions
exit 0
