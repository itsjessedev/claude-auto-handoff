#!/bin/bash
# Pre-Compact Hook - Automatically trigger handoff before compaction
#
# Uses manifest-based handoff system for reliable identification.
# Extracts actual context from transcript for meaningful handoffs.

# Load shared libraries
source "$HOME/.claude/hooks/lib/get-channel.sh"
source "$HOME/.claude/hooks/lib/handoff-manifest.sh"

CHANNEL=$(get_channel)
TIMESTAMP=$(date +"%Y-%m-%d %H:%M")

# Get session info
SESSION_ID=$(get_current_session_id)
TRANSCRIPT=$(get_current_transcript_path)

# Extract recent context from transcript if available
RECENT_CONTEXT=""
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
    RECENT_CONTEXT=$(extract_recent_context "$TRANSCRIPT")
fi

# Build handoff content with actual context
HANDOFF_CONTENT=$(cat << EOF
# Auto-Handoff (Pre-Compaction)

**Timestamp:** $TIMESTAMP
**Project:** $PWD
**Channel:** $CHANNEL
**Session:** ${SESSION_ID:-unknown}

## Auto-Compaction Triggered

Context was getting full and auto-compaction was about to run.
This handoff was created automatically to preserve context.

## Recent Activity

\`\`\`
${RECENT_CONTEXT:-No recent context extracted}
\`\`\`

## Instructions for Claude

1. Call \`context_get({ channel: '$CHANNEL', priorities: ['high'] })\`
2. Check for any plan files in \`~/.claude/plans/\`
3. Announce: "Restored from auto-handoff. Channel: $CHANNEL"
4. Continue where we left off

## Notes

This was an automatic handoff, not user-initiated.
Check memory-keeper for the most recent task and progress.
EOF
)

# Create handoff using manifest system
HANDOFF_ID=$(create_handoff "$CHANNEL" "$HANDOFF_CONTENT" "auto")

if [ -n "$HANDOFF_ID" ]; then
    # Log success (silent to Claude, visible in logs)
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Created handoff: $HANDOFF_ID for channel: $CHANNEL" >> "$HOME/.claude/auto-session.log"
fi

# Clean up any old lock files for this channel (we're ending via compaction)
LOCK_DIR="$HOME/.claude/handoff/${CHANNEL}.lock.d"
if [ -d "$LOCK_DIR" ]; then
    MY_PID="$PPID"
    LOCK_PID=$(cat "$LOCK_DIR/pid" 2>/dev/null | cut -d: -f1)
    if [ "$LOCK_PID" = "$MY_PID" ]; then
        rm -rf "$LOCK_DIR"
    fi
fi

exit 0
