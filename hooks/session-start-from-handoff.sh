#!/bin/bash
# Session Start Hook - Auto-preload handoffs and context
#
# Uses manifest-based handoff system for reliable loading.
# CRITICAL RULES are ALWAYS injected on every session (fresh, resume, handoff)

HANDOFF_DIR="$HOME/.claude/handoff"
CRITICAL_RULES_FILE="$HOME/.claude/CRITICAL-RULES.md"

mkdir -p "$HANDOFF_DIR"

# Load shared libraries
source "$HOME/.claude/hooks/lib/get-channel.sh"
source "$HOME/.claude/hooks/lib/handoff-manifest.sh"

# Capture session origin directory (prevents pwd drift from breaking channel detection)
# Uses PPID (Claude's PID) for isolation between parallel sessions
ORIGIN_FILE="$HOME/.claude/.session-origin-$PPID"
echo "$PWD" > "$ORIGIN_FILE"

# Cleanup old origin files (from dead PIDs) in background
find "$HOME/.claude" -name ".session-origin-*" -mmin +120 -delete 2>/dev/null &

# Cleanup old archived handoffs in background (non-blocking)
find "$HANDOFF_DIR/archive" -name "*.md" -mmin +10080 -delete 2>/dev/null &

# Load and escape critical rules (these get injected EVERY session)
CRITICAL_RULES=""
if [ -f "$CRITICAL_RULES_FILE" ]; then
    if command -v python3 >/dev/null 2>&1; then
        CRITICAL_RULES=$(cat "$CRITICAL_RULES_FILE" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read())[1:-1])')
    else
        CRITICAL_RULES=$(cat "$CRITICAL_RULES_FILE" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' '\036' | sed 's/\036/\\n/g')
    fi
fi

# Load system context (environment facts - machines, connections, etc.)
SYSTEM_CONTEXT_FILE="$HOME/.claude/system-context.md"
SYSTEM_CONTEXT=""
if [ -f "$SYSTEM_CONTEXT_FILE" ]; then
    if command -v python3 >/dev/null 2>&1; then
        SYSTEM_CONTEXT=$(cat "$SYSTEM_CONTEXT_FILE" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read())[1:-1])')
    else
        SYSTEM_CONTEXT=$(cat "$SYSTEM_CONTEXT_FILE" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' '\036' | sed 's/\036/\\n/g')
    fi
    SYSTEM_CONTEXT="\\n\\n=== SYSTEM CONTEXT ===\\n\\n$SYSTEM_CONTEXT"
fi

# Load general knowledge tracker (Jesse's understanding levels)
KNOWLEDGE_TRACKER_FILE="$HOME/.claude/knowledge-tracker.md"
KNOWLEDGE_TRACKER=""
if [ -f "$KNOWLEDGE_TRACKER_FILE" ]; then
    if command -v python3 >/dev/null 2>&1; then
        KNOWLEDGE_TRACKER=$(cat "$KNOWLEDGE_TRACKER_FILE" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read())[1:-1])')
    else
        KNOWLEDGE_TRACKER=$(cat "$KNOWLEDGE_TRACKER_FILE" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' '\036' | sed 's/\036/\\n/g')
    fi
    KNOWLEDGE_TRACKER="\\n\\n=== KNOWLEDGE TRACKER ===\\n\\n$KNOWLEDGE_TRACKER"
fi

# Load domain-specific knowledge based on path (uses domain-registry.json)
DOMAIN_KNOWLEDGE=""
DOMAIN_KNOWLEDGE_DIR="$HOME/.claude/domain-knowledge"
DOMAIN_REGISTRY="$HOME/.claude/domain-registry.json"
DOMAIN_FILE=""

# Find matching domain from registry (longest path match wins)
if [ -f "$DOMAIN_REGISTRY" ] && command -v python3 >/dev/null 2>&1; then
    DOMAIN_FILE=$(python3 << PYEOF
import json
import os

registry_path = "$DOMAIN_REGISTRY"
current_dir = "$PWD"
domain_dir = "$DOMAIN_KNOWLEDGE_DIR"

try:
    with open(registry_path) as f:
        registry = json.load(f)

    domains = registry.get("domains", {})
    best_match = ""
    best_file = ""

    for path, filename in domains.items():
        if current_dir.startswith(path) and len(path) > len(best_match):
            best_match = path
            best_file = filename

    if best_file:
        print(os.path.join(domain_dir, best_file))
except:
    pass
PYEOF
)
fi
if [ -n "$DOMAIN_FILE" ] && [ -f "$DOMAIN_FILE" ]; then
    if command -v python3 >/dev/null 2>&1; then
        DOMAIN_KNOWLEDGE=$(cat "$DOMAIN_FILE" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read())[1:-1])')
    else
        DOMAIN_KNOWLEDGE=$(cat "$DOMAIN_FILE" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' '\036' | sed 's/\036/\\n/g')
    fi
    DOMAIN_KNOWLEDGE="\\n\\n=== DOMAIN KNOWLEDGE ===\\n\\n$DOMAIN_KNOWLEDGE"
fi

# Find PROJECT-RULES.md (check current dir, then walk up to find nearest)
find_project_rules() {
    local dir="$1"
    while [ "$dir" != "/" ] && [ "$dir" != "$HOME" ]; do
        if [ -f "$dir/PROJECT-RULES.md" ]; then
            echo "$dir/PROJECT-RULES.md"
            return
        fi
        dir=$(dirname "$dir")
    done
    echo ""
}
PROJECT_RULES_FILE=$(find_project_rules "$PWD")
PROJECT_RULES=""
if [ -n "$PROJECT_RULES_FILE" ] && [ -f "$PROJECT_RULES_FILE" ]; then
    if command -v python3 >/dev/null 2>&1; then
        PROJECT_RULES=$(cat "$PROJECT_RULES_FILE" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read())[1:-1])')
    else
        PROJECT_RULES=$(cat "$PROJECT_RULES_FILE" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' '\036' | sed 's/\036/\\n/g')
    fi
    PROJECT_RULES="\\n\\n=== PROJECT RULES ($(dirname $PROJECT_RULES_FILE)) ===\\n\\n$PROJECT_RULES"
fi

# Combine all rules
ALL_RULES="${CRITICAL_RULES}${SYSTEM_CONTEXT}${KNOWLEDGE_TRACKER}${DOMAIN_KNOWLEDGE}${PROJECT_RULES}"

# Get channel for this session
CHANNEL=$(get_channel)
MY_PID="$PPID"

# Check if a PID is still running
is_pid_alive() {
    local pid="$1"
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# Lock handling for parallel sessions
LOCK_DIR="$HANDOFF_DIR/${CHANNEL}.lock.d"
LOCK_FILE="$LOCK_DIR/pid"

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

if [ "$PARALLEL_SESSION" = true ]; then
    # Another session is active - start fresh
    cat << EOF
{
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": "=== PARALLEL SESSION (Channel: $CHANNEL) ===\n\nAnother Claude instance is active (PID: $LOCK_PID).\nStarting fresh to avoid conflicts.\n\nWorking directory: $PWD\n\nTo load shared context: context_get({ channel: '$CHANNEL', priorities: ['high'] })\n\n$ALL_RULES"
    }
}
EOF
    exit 0
fi

# Try to load handoff using manifest system
HANDOFF_CONTENT=$(load_handoff "$CHANNEL" "$MY_PID")
LOAD_RESULT=$?

if [ $LOAD_RESULT -eq 0 ] && [ -n "$HANDOFF_CONTENT" ]; then
    # Successfully loaded handoff from manifest

    # Get handoff metadata from the content header
    HANDOFF_ID=$(echo "$HANDOFF_CONTENT" | head -10 | grep -o 'HANDOFF-ID: [^-]*-[^-]*-[^-]*-[a-f0-9]*' | cut -d' ' -f2)
    PREV_SESSION=$(echo "$HANDOFF_CONTENT" | head -10 | grep -o 'SESSION: [^ ]*' | cut -d' ' -f2 | tr -d '>' )
    HANDOFF_TYPE=$(echo "$HANDOFF_CONTENT" | head -10 | grep -o 'TYPE: [a-z]*' | cut -d' ' -f2)

    # Archive previous transcript (background)
    "$HOME/.claude/hooks/archive-manager.sh" auto >/dev/null 2>&1 &

    # JSON-escape the handoff content for additionalContext
    if command -v python3 >/dev/null 2>&1; then
        ESCAPED_CONTENT=$(echo "$HANDOFF_CONTENT" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read())[1:-1])')
    else
        ESCAPED_CONTENT=$(echo "$HANDOFF_CONTENT" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' '\036' | sed 's/\036/\\n/g')
    fi

    # Verify escaping worked (non-empty result)
    if [ -z "$ESCAPED_CONTENT" ]; then
        cat << EOF
{
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": "=== HANDOFF LOAD ERROR ===\nChannel: $CHANNEL\n\nFailed to escape handoff content.\n\n$ALL_RULES"
    }
}
EOF
        exit 0
    fi

    cat << EOF
{
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": "=== HANDOFF LOADED (ID: ${HANDOFF_ID:-unknown}) ===\nChannel: $CHANNEL\nPrevious Session: ${PREV_SESSION:-unknown}\nType: ${HANDOFF_TYPE:-unknown}\n\n$ESCAPED_CONTENT\n\n=== END HANDOFF ===\n\nThe handoff content above is ALREADY in your context. Do NOT use Glob, Grep, or Read to find/read the handoff file - it has been consumed and archived. Just continue from the handoff state above.\n\n$ALL_RULES"
    }
}
EOF
    exit 0
fi

# No handoff found - check for old unconsumed handoffs (notify but don't auto-load)
OLD_HANDOFF_NOTICE=""
if [ -f "$HANDOFF_DIR/${CHANNEL}-CURRENT.md" ]; then
    # There's a handoff file but manifest didn't allow loading (maybe expired?)
    MANIFEST_STATUS=$(read_manifest "$CHANNEL" | jq -r '.current.status // "none"')
    if [ "$MANIFEST_STATUS" = "expired" ]; then
        OLD_HANDOFF_NOTICE="\\n\\n\u26a0\ufe0f EXPIRED HANDOFF AVAILABLE:\\n$HANDOFF_DIR/${CHANNEL}-CURRENT.md\\nTo load manually: Read the file above"
    fi
fi

# Normal start (no handoff)
cat << EOF
{
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": "=== SESSION START (Channel: $CHANNEL) ===\n\nWorking directory: $PWD${OLD_HANDOFF_NOTICE}\n\nLoad context: context_get({ channel: '$CHANNEL', priorities: ['high'] })\n\nChannel registry: ~/.claude/channel-registry.json\n\n$ALL_RULES"
    }
}
EOF
