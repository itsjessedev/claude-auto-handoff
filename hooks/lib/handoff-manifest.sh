#!/bin/bash
# Handoff Manifest Library - Single source of truth for handoffs
#
# This library provides atomic, manifest-based handoff management.
# All handoff operations go through this library to ensure:
# - Single source of truth (manifest file)
# - Traceable IDs linked to sessions
# - Atomic operations (temp+rename)
# - Verification (ID in file matches manifest)
#
# Usage:
#   source ~/.claude/hooks/lib/handoff-manifest.sh
#   HANDOFF_ID=$(create_handoff "$CHANNEL" "$CONTENT" "auto")
#   CONTENT=$(load_handoff "$CHANNEL" "$$")

HANDOFF_DIR="$HOME/.claude/handoff"
HANDOFF_ARCHIVE_DIR="$HANDOFF_DIR/archive"
CURRENT_SESSION_FILE="$HOME/.claude/.current-session"

# Ensure directories exist
mkdir -p "$HANDOFF_DIR" "$HANDOFF_ARCHIVE_DIR" 2>/dev/null

# Get current session ID from wrapper's tracking file
# Returns: session UUID or empty string
get_current_session_id() {
    [ -f "$CURRENT_SESSION_FILE" ] && cut -d: -f1 "$CURRENT_SESSION_FILE" 2>/dev/null
}

# Get current transcript path from wrapper's tracking file
# Returns: path to .jsonl transcript or empty string
get_current_transcript_path() {
    [ -f "$CURRENT_SESSION_FILE" ] && cut -d: -f2 "$CURRENT_SESSION_FILE" 2>/dev/null
}

# Generate unique handoff ID
# Format: HO-{YYYYMMDD}-{HHMMSS}-{session_prefix_8chars}
# Args: $1 = session_id (optional, uses current if not provided)
# Returns: handoff ID string
generate_handoff_id() {
    local session_id="${1:-$(get_current_session_id)}"
    local timestamp=$(date +%Y%m%d-%H%M%S)
    # Take first 8 chars and remove non-alphanumeric to keep ID format clean
    local prefix=$(echo "${session_id:0:8}" | tr -cd 'a-zA-Z0-9')
    [ -z "$prefix" ] && prefix="nosess"
    echo "HO-${timestamp}-${prefix}"
}

# Read manifest for a channel
# Args: $1 = channel name
# Returns: JSON content or empty string
read_manifest() {
    local channel="$1"
    local manifest="$HANDOFF_DIR/${channel}.manifest.json"
    [ -f "$manifest" ] && cat "$manifest"
}

# Atomic write manifest
# Args: $1 = channel name, $2 = JSON content
# Returns: 0 on success, 1 on failure
write_manifest() {
    local channel="$1"
    local content="$2"
    local manifest="$HANDOFF_DIR/${channel}.manifest.json"
    local tmp="${manifest}.tmp.$$"

    echo "$content" > "$tmp" && mv "$tmp" "$manifest"
}

# Create a handoff file with manifest tracking
# Args: $1 = channel, $2 = content, $3 = type (auto|manual|bye)
# Returns: handoff ID on success, empty on failure
create_handoff() {
    local channel="$1"
    local content="$2"
    local type="${3:-auto}"

    local session_id=$(get_current_session_id)
    local handoff_id=$(generate_handoff_id "$session_id")
    local handoff_file="$HANDOFF_DIR/${channel}-CURRENT.md"
    local created_at=$(date -Iseconds)

    mkdir -p "$HANDOFF_DIR" "$HANDOFF_ARCHIVE_DIR"

    # Archive existing handoff if present
    if [ -f "$handoff_file" ]; then
        local old_id=$(head -5 "$handoff_file" 2>/dev/null | grep -oE 'HO-[0-9]{8}-[0-9]{6}-[a-zA-Z0-9]+')
        if [ -n "$old_id" ]; then
            mv "$handoff_file" "$HANDOFF_ARCHIVE_DIR/${old_id}.md" 2>/dev/null
        else
            # No ID found, archive with timestamp
            mv "$handoff_file" "$HANDOFF_ARCHIVE_DIR/${channel}-$(date +%Y%m%d-%H%M%S).md" 2>/dev/null
        fi
    fi

    # Write new handoff with header
    cat > "$handoff_file" << EOF
<!-- HANDOFF-ID: $handoff_id -->
<!-- SESSION: ${session_id:-unknown} -->
<!-- CHANNEL: $channel -->
<!-- CREATED: $created_at -->
<!-- TYPE: $type -->
<!-- WORKING-DIR: $PWD -->

$content
EOF

    # Update manifest atomically
    write_manifest "$channel" "$(cat << MANIFEST
{
  "channel": "$channel",
  "current": {
    "id": "$handoff_id",
    "session_id": "${session_id:-unknown}",
    "created_at": "$created_at",
    "created_by_pid": $$,
    "working_dir": "$PWD",
    "type": "$type",
    "status": "active"
  }
}
MANIFEST
)"

    echo "$handoff_id"
}

# Load handoff for a channel (marks as consumed)
# Args: $1 = channel, $2 = consumer PID (optional, defaults to $$)
# Returns: handoff content on stdout, 0 on success, 1 on failure
# Side effects: archives handoff file, updates manifest to consumed
load_handoff() {
    local channel="$1"
    local consumer_pid="${2:-$$}"

    local manifest=$(read_manifest "$channel")
    [ -z "$manifest" ] && return 1

    local status=$(echo "$manifest" | jq -r '.current.status // "none"')
    [ "$status" != "active" ] && return 1

    local handoff_file="$HANDOFF_DIR/${channel}-CURRENT.md"
    [ ! -f "$handoff_file" ] && return 1

    # Verify ID matches between file and manifest
    # ID format: HO-YYYYMMDD-HHMMSS-prefix (prefix is alphanumeric)
    local file_id=$(head -5 "$handoff_file" 2>/dev/null | grep -oE 'HO-[0-9]{8}-[0-9]{6}-[a-zA-Z0-9]+')
    local manifest_id=$(echo "$manifest" | jq -r '.current.id')

    if [ "$file_id" != "$manifest_id" ]; then
        echo "ERROR: ID mismatch - file:$file_id manifest:$manifest_id" >&2
        return 1
    fi

    # Check age (2 hour max)
    local created=$(echo "$manifest" | jq -r '.current.created_at')
    local created_epoch=$(date -d "$created" +%s 2>/dev/null || echo 0)
    local now_epoch=$(date +%s)
    local age=$((now_epoch - created_epoch))

    if [ "$age" -gt 7200 ]; then
        # Too old - mark as expired but don't delete
        local updated=$(echo "$manifest" | jq --arg now "$(date -Iseconds)" '
          .current.status = "expired" |
          .current.expired_at = $now
        ')
        write_manifest "$channel" "$updated"
        return 1
    fi

    # Read content
    local content=$(cat "$handoff_file")

    # Update manifest to consumed
    local updated=$(echo "$manifest" | jq --arg pid "$consumer_pid" --arg now "$(date -Iseconds)" '
      .current.status = "consumed" |
      .current.consumed_by_pid = ($pid | tonumber) |
      .current.consumed_at = $now
    ')
    write_manifest "$channel" "$updated"

    # Archive file
    mv "$handoff_file" "$HANDOFF_ARCHIVE_DIR/${manifest_id}.md" 2>/dev/null

    echo "$content"
    return 0
}

# Get active handoff file path (for wrapper display)
# Args: $1 = channel
# Returns: path to handoff file or empty string
get_active_handoff_file() {
    local channel="$1"
    local manifest=$(read_manifest "$channel")
    [ -z "$manifest" ] && return 1

    local status=$(echo "$manifest" | jq -r '.current.status // "none"')
    [ "$status" != "active" ] && return 1

    local handoff_file="$HANDOFF_DIR/${channel}-CURRENT.md"
    [ -f "$handoff_file" ] && echo "$handoff_file"
}

# Get handoff ID from an active handoff
# Args: $1 = channel
# Returns: handoff ID or empty string
get_active_handoff_id() {
    local channel="$1"
    local manifest=$(read_manifest "$channel")
    [ -z "$manifest" ] && return 1

    local status=$(echo "$manifest" | jq -r '.current.status // "none"')
    [ "$status" != "active" ] && return 1

    echo "$manifest" | jq -r '.current.id'
}

# Check if handoff exists and is active
# Args: $1 = channel
# Returns: 0 if active handoff exists, 1 otherwise
has_active_handoff() {
    local channel="$1"
    local manifest=$(read_manifest "$channel")
    [ -z "$manifest" ] && return 1

    local status=$(echo "$manifest" | jq -r '.current.status // "none"')
    [ "$status" = "active" ]
}

# Clear/invalidate a handoff without consuming it (for cleanup)
# Args: $1 = channel
# Returns: 0 on success
clear_handoff() {
    local channel="$1"
    local manifest=$(read_manifest "$channel")
    [ -z "$manifest" ] && return 0

    local handoff_id=$(echo "$manifest" | jq -r '.current.id // ""')
    local handoff_file="$HANDOFF_DIR/${channel}-CURRENT.md"

    # Archive file if exists
    if [ -f "$handoff_file" ] && [ -n "$handoff_id" ]; then
        mv "$handoff_file" "$HANDOFF_ARCHIVE_DIR/${handoff_id}.md" 2>/dev/null
    elif [ -f "$handoff_file" ]; then
        mv "$handoff_file" "$HANDOFF_ARCHIVE_DIR/${channel}-$(date +%Y%m%d-%H%M%S).md" 2>/dev/null
    fi

    # Update manifest to cleared
    local updated=$(echo "$manifest" | jq --arg now "$(date -Iseconds)" '
      .current.status = "cleared" |
      .current.cleared_at = $now
    ')
    write_manifest "$channel" "$updated"

    return 0
}

# Extract recent context from a transcript file
# Args: $1 = transcript path
# Returns: summary of recent activity on stdout
extract_recent_context() {
    local transcript="$1"
    [ ! -f "$transcript" ] && return 1

    # Get last ~100 lines and extract meaningful content
    tail -100 "$transcript" 2>/dev/null | jq -r '
      select(.type == "user" or .type == "assistant") |
      select(.message.content != null) |
      .type as $type |
      (.message.content | if type == "array" then .[0].text // .[0] else . end) |
      if type == "string" then
        "\($type): \(.[0:300])"
      else
        empty
      end
    ' 2>/dev/null | tail -15
}

# Write session tracking file (called by wrapper)
# Args: $1 = session_id, $2 = transcript_path
write_session_file() {
    local session_id="$1"
    local transcript_path="$2"
    echo "${session_id}:${transcript_path}" > "$CURRENT_SESSION_FILE"
}

# Clear session tracking file (called by wrapper on clean exit)
clear_session_file() {
    rm -f "$CURRENT_SESSION_FILE"
}

# If run directly (not sourced), show status
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Handoff Manifest Library"
    echo "========================"
    echo "HANDOFF_DIR: $HANDOFF_DIR"
    echo "ARCHIVE_DIR: $HANDOFF_ARCHIVE_DIR"
    echo ""

    if [ -f "$CURRENT_SESSION_FILE" ]; then
        echo "Current Session:"
        echo "  ID: $(get_current_session_id)"
        echo "  Transcript: $(get_current_transcript_path)"
    else
        echo "No active session tracked"
    fi
    echo ""

    echo "Active Handoffs:"
    for manifest in "$HANDOFF_DIR"/*.manifest.json; do
        [ -f "$manifest" ] || continue
        channel=$(basename "$manifest" .manifest.json)
        status=$(jq -r '.current.status // "none"' "$manifest")
        id=$(jq -r '.current.id // "none"' "$manifest")
        echo "  $channel: $status ($id)"
    done
fi
