#!/bin/bash
# Simple Threshold Monitor
# Just watches transcript sizes - user runs Claude sessions manually
#
# Usage: ./simple-threshold-monitor.sh
# Then in another terminal, run Claude and work until context fills
# This script logs sizes every 15 seconds

LOG_FILE="$HOME/.claude/threshold-monitor.log"
FINDINGS_FILE="$HOME/.claude/threshold-findings.md"

echo "=== Threshold Monitor Started ===" | tee "$LOG_FILE"
echo "Timestamp: $(date)" | tee -a "$LOG_FILE"
echo "Press Ctrl+C to stop" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# Track peak size
PEAK_SIZE=0
PEAK_FILE=""

while true; do
    # Find newest transcript
    TRANSCRIPT=$(find ~/.claude/projects -name "*.jsonl" -mmin -5 -type f 2>/dev/null | grep -v subagents | xargs -r ls -t 2>/dev/null | head -1)

    if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
        SIZE=$(stat -c %s "$TRANSCRIPT" 2>/dev/null || echo 0)
        SIZE_KB=$((SIZE / 1024))

        # Update peak
        if [ "$SIZE" -gt "$PEAK_SIZE" ]; then
            PEAK_SIZE=$SIZE
            PEAK_FILE=$TRANSCRIPT
        fi

        echo "[$(date '+%H:%M:%S')] ${SIZE_KB}KB - $(basename $TRANSCRIPT)" | tee -a "$LOG_FILE"

        # Check for context warnings in recent Claude output
        # (This is approximate - Claude's warning appears in the TUI)
        if [ "$SIZE_KB" -gt 1700 ]; then
            echo "  ⚠️ APPROACHING LIMIT (>1700KB)" | tee -a "$LOG_FILE"
        fi
    else
        echo "[$(date '+%H:%M:%S')] No active transcript" | tee -a "$LOG_FILE"
    fi

    sleep 15
done

# On exit, save findings
trap "echo ''; echo 'Peak size: $((PEAK_SIZE/1024))KB'; echo 'File: $PEAK_FILE'" EXIT
