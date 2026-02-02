#!/bin/bash
# Channel detection utility - ALWAYS use this, never hardcode channels
#
# Usage:
#   source ~/.claude/hooks/lib/get-channel.sh
#   CHANNEL=$(get_channel)
#   CHANNEL=$(get_channel "/some/specific/path")

get_channel() {
    local registry="$HOME/.claude/channel-registry.json"
    local cwd

    # Priority: 1) explicit argument, 2) session origin file, 3) current pwd
    # Session origin prevents pwd drift from breaking channel detection

    if [[ -n "$1" ]]; then
        cwd="$1"  # Explicit path argument takes priority
    else
        # Find session origin file (PID-specific for parallel session isolation)
        # Try current shell's ancestors to find the Claude session's origin
        local origin_file=""
        local check_pid=$$
        for _ in 1 2 3 4 5; do  # Check up to 5 ancestors
            if [[ -f "$HOME/.claude/.session-origin-$check_pid" ]]; then
                origin_file="$HOME/.claude/.session-origin-$check_pid"
                break
            fi
            # Move to parent
            check_pid=$(ps -o ppid= -p "$check_pid" 2>/dev/null | tr -d ' ')
            [[ -z "$check_pid" || "$check_pid" == "1" ]] && break
        done

        if [[ -n "$origin_file" && -f "$origin_file" ]]; then
            cwd=$(cat "$origin_file")
        else
            cwd="$(pwd)"  # Fallback to current directory
        fi
    fi

    # Default fallback
    if [[ ! -f "$registry" ]]; then
        echo "global"
        return
    fi

    local best_match=""
    local best_channel="global"

    # Extract path:channel pairs from registry
    # Format: "/path/to/dir": "channel-name"
    while IFS= read -r line; do
        # Extract path (between first pair of quotes)
        local path=$(echo "$line" | sed -n 's/.*"\(\/[^"]*\)".*/\1/p')
        # Extract channel (after the colon, between quotes)
        local channel=$(echo "$line" | sed -n 's/.*: *"\([^"]*\)".*/\1/p')

        [[ -z "$path" || -z "$channel" ]] && continue

        # Check if cwd starts with this path
        if [[ "$cwd" == "$path" || "$cwd" == "$path"/* ]]; then
            # Longest match wins
            if [[ ${#path} -gt ${#best_match} ]]; then
                best_match="$path"
                best_channel="$channel"
            fi
        fi
    done < <(grep -E '^\s*"/' "$registry")

    echo "$best_channel"
}

# If run directly (not sourced), output the channel
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    get_channel "$@"
fi
