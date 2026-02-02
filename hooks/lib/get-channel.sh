#!/bin/bash
# Channel detection utility - ALWAYS use this, never hardcode channels
#
# Usage:
#   source ~/.claude/hooks/lib/get-channel.sh
#   CHANNEL=$(get_channel)
#   CHANNEL=$(get_channel "/some/specific/path")

get_channel() {
    local cwd="${1:-$(pwd)}"
    local registry="$HOME/.claude/channel-registry.json"

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
