#!/bin/bash
# Session Start Hook - Load handoff when explicitly requested
# Supports multiple concurrent instances via PID-based handoffs and locks
#
# Handoffs are ONLY loaded when:
# 1. CLAUDE_LOAD_HANDOFF=1 env var is set (set by wrapper on auto-restart)
# 2. User explicitly resumed with -r flag (detected by resume matcher)
#
# This prevents loading stale handoffs on fresh starts.

HANDOFF_DIR="$HOME/.claude/handoff"
LOAD_HANDOFF_FLAG="$HOME/.claude/.load-handoff"

mkdir -p "$HANDOFF_DIR"

# Check if we should load handoffs
# Flag file is created by wrapper before auto-restart
SHOULD_LOAD_HANDOFF=false
if [ -f "$LOAD_HANDOFF_FLAG" ]; then
    SHOULD_LOAD_HANDOFF=true
    rm -f "$LOAD_HANDOFF_FLAG"
fi

# Use shared channel detection utility
source "$HOME/.claude/hooks/lib/get-channel.sh"

# Check if a PID is still running
is_pid_alive() {
    local pid="$1"
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

CHANNEL=$(get_channel)
LOCK_DIR="$HANDOFF_DIR/${CHANNEL}.lock.d"  # Use directory for atomic creation
LOCK_FILE="$LOCK_DIR/pid"
MY_PID="$PPID"

# Atomic lock acquisition using mkdir (POSIX atomic operation)
acquire_lock() {
    # Try to create lock directory atomically
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        # We got the lock - write our PID
        echo "${MY_PID}:$(date +%s)" > "$LOCK_FILE"
        return 0  # Lock acquired
    fi

    # Lock exists - check if owner is alive
    if [ -f "$LOCK_FILE" ]; then
        LOCK_PID=$(cat "$LOCK_FILE" 2>/dev/null | cut -d: -f1)
        if is_pid_alive "$LOCK_PID"; then
            return 1  # Another session is active
        fi
    fi

    # Owner is dead - remove stale lock and retry once
    rm -rf "$LOCK_DIR"
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        echo "${MY_PID}:$(date +%s)" > "$LOCK_FILE"
        return 0  # Lock acquired
    fi

    return 1  # Lost race to another session
}

# Check for existing lock (another active session in this channel)
PARALLEL_SESSION=false
if ! acquire_lock; then
    PARALLEL_SESSION=true
    LOCK_PID=$(cat "$LOCK_FILE" 2>/dev/null | cut -d: -f1)
fi

# Find available handoff files (from dead PIDs) for this channel
find_handoff() {
    local best_file=""
    local best_time=0

    for f in "$HANDOFF_DIR/${CHANNEL}"-*.md "$HANDOFF_DIR/${CHANNEL}.md"; do
        [ -f "$f" ] || continue

        # Check age (skip if older than 2 hours)
        local age=$(( $(date +%s) - $(stat -c %Y "$f" 2>/dev/null || echo 0) ))
        [ "$age" -gt 7200 ] && continue

        # Extract PID from filename (format: channel-PID.md)
        local fname=$(basename "$f")
        local file_pid=$(echo "$fname" | sed -n "s/${CHANNEL}-\([0-9]*\)\.md/\1/p")

        # If it has a PID in filename, check if that PID is dead
        if [ -n "$file_pid" ]; then
            if is_pid_alive "$file_pid"; then
                # PID still alive - this handoff belongs to another active session
                continue
            fi
        fi

        # This handoff is available (no PID or dead PID)
        local mtime=$(stat -c %Y "$f" 2>/dev/null || echo 0)
        if [ "$mtime" -gt "$best_time" ]; then
            best_time="$mtime"
            best_file="$f"
        fi
    done

    echo "$best_file"
}

if [ "$PARALLEL_SESSION" = true ]; then
    # Another session is active - start fresh
    cat << EOF
{
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": "=== PARALLEL SESSION (Channel: $CHANNEL) ===\n\nAnother Claude instance is active (PID: $LOCK_PID).\nStarting fresh to avoid conflicts.\n\nWorking directory: $PWD\n\nTo load shared context: context_get({ channel: '$CHANNEL', priorities: ['high'] })"
    }
}
EOF
    exit 0
fi

# Only look for handoff if we should load one (auto-restart or explicit resume)
HANDOFF_FILE=""
if [ "$SHOULD_LOAD_HANDOFF" = true ]; then
    HANDOFF_FILE=$(find_handoff)
fi

if [ -n "$HANDOFF_FILE" ] && [ -f "$HANDOFF_FILE" ]; then
    # Read content (handle race condition if file disappears)
    HANDOFF_CONTENT=$(cat "$HANDOFF_FILE" 2>/dev/null) || {
        # File disappeared between find and read - start fresh
        cat << EOF
{
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": "=== SESSION START (Channel: $CHANNEL) ===\n\nHandoff file disappeared (race condition). Starting fresh.\n\nWorking directory: $PWD"
    }
}
EOF
        exit 0
    }

    ARCHIVE_DIR="$HOME/.claude/archives/$CHANNEL"
    HANDOFF_ID=$(basename "$HANDOFF_FILE" .md)
    PREV_PID=$(echo "$HANDOFF_ID" | sed 's/.*-//')

    # Archive previous transcript (background)
    "$HOME/.claude/hooks/archive-manager.sh" auto >/dev/null 2>&1 &

    # JSON-escape the handoff content for additionalContext
    # Try python3 first, fall back to simple sed escaping
    if command -v python3 >/dev/null 2>&1; then
        ESCAPED_CONTENT=$(echo "$HANDOFF_CONTENT" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read())[1:-1])')
    else
        # Fallback: basic escaping (newlines to \n, quotes to \", backslashes to \\)
        ESCAPED_CONTENT=$(echo "$HANDOFF_CONTENT" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' '\036' | sed 's/\036/\\n/g')
    fi

    # Verify escaping worked (non-empty result)
    if [ -z "$ESCAPED_CONTENT" ]; then
        # Escaping failed - fall back to just notifying with file path
        cat << EOF
{
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": "=== HANDOFF AVAILABLE ===\nChannel: $CHANNEL\nFile: $HANDOFF_FILE\n\nEscaping failed. Read file manually: Read $HANDOFF_FILE"
    }
}
EOF
        exit 0
    fi

    cat << EOF
{
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": "=== HANDOFF LOADED ===\nChannel: $CHANNEL\nHandoff ID: $HANDOFF_ID\nPrevious PID: $PREV_PID\n\n$ESCAPED_CONTENT\n\n=== END HANDOFF ==="
    }
}
EOF
    # Clean up handoff file after including in context
    rm -f "$HANDOFF_FILE"
    exit 0
fi

# Check if there are pending handoffs we're NOT auto-loading (manual start)
PENDING_HANDOFFS=""
for f in "$HANDOFF_DIR/${CHANNEL}"-*.md "$HANDOFF_DIR/${CHANNEL}.md"; do
    [ -f "$f" ] || continue
    PENDING_HANDOFFS="$PENDING_HANDOFFS $(basename $f)"
done

if [ -n "$PENDING_HANDOFFS" ]; then
    # Normal start but handoffs exist - notify without auto-loading
    cat << EOF
{
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": "=== SESSION START (Channel: $CHANNEL) ===\n\n⚠️ PENDING HANDOFFS FOUND:$PENDING_HANDOFFS\nTo load: Read ~/.claude/handoff/{filename}\n\nWorking directory: $PWD"
    }
}
EOF
else
    # No handoff - normal start
    cat << EOF
{
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": "=== SESSION START (Channel: $CHANNEL) ===\n\nWorking directory: $PWD\n\nLoad context: context_get({ channel: '$CHANNEL', priorities: ['high'] })\n\nChannel registry: ~/.claude/channel-registry.json"
    }
}
EOF
fi
