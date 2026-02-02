#!/bin/bash
# Autonomous Context Threshold Tester
# Run this and go to bed - it will find the actual limit
#
# Usage: ./test-threshold.sh [content-type]
#   content-type: code, prose, mixed (default: mixed)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$HOME/.claude/threshold-test-$(date +%Y%m%d-%H%M%S).log"
RESULTS_FILE="$HOME/.claude/threshold-results.json"
TEST_DIR=$(mktemp -d)
CONTENT_TYPE="${1:-mixed}"

# Find real claude binary (not wrapper)
CLAUDE_BIN=""
for c in "$HOME/.local/bin/claude" "/usr/local/bin/claude" "/usr/bin/claude"; do
    [ -x "$c" ] && CLAUDE_BIN="$c" && break
done
[ -z "$CLAUDE_BIN" ] && CLAUDE_BIN=$(which claude)

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

get_transcript_size() {
    find ~/.claude/projects -name "*.jsonl" -mmin -5 -type f 2>/dev/null | \
        grep -v subagents | \
        xargs -r ls -t 2>/dev/null | \
        head -1 | \
        xargs -r stat -c %s 2>/dev/null || echo "0"
}

log "=== Context Threshold Test Started ==="
log "Content type: $CONTENT_TYPE"
log "Log file: $LOG_FILE"
log "Claude binary: $CLAUDE_BIN"
log ""

# Create test content based on type
case "$CONTENT_TYPE" in
    code)
        # Generate a large code file
        TEST_FILE="$TEST_DIR/test-code.ts"
        log "Generating code test file..."
        for i in $(seq 1 200); do
            cat >> "$TEST_FILE" << EOF
// Function $i - demonstrating various TypeScript patterns
export async function processData$i(input: Record<string, unknown>): Promise<{
    success: boolean;
    data: typeof input;
    timestamp: number;
    iteration: number;
}> {
    const startTime = Date.now();
    const processed = Object.entries(input).reduce((acc, [key, value]) => {
        acc[key.toUpperCase()] = typeof value === 'string' ? value.trim() : value;
        return acc;
    }, {} as Record<string, unknown>);

    return {
        success: true,
        data: processed,
        timestamp: startTime,
        iteration: $i
    };
}

EOF
        done
        PROMPT="Read the file $TEST_FILE and analyze it. Then explain each function. Keep going until you've covered all functions or hit an error."
        ;;
    prose)
        # Generate prose content
        TEST_FILE="$TEST_DIR/test-prose.md"
        log "Generating prose test file..."
        for i in $(seq 1 100); do
            cat >> "$TEST_FILE" << EOF
## Chapter $i: The Continuing Saga

In this section, we explore the intricate details of software development practices
that have evolved over the decades. The methodologies employed by modern teams
reflect a synthesis of historical approaches and cutting-edge innovations.

Consider the implications of distributed systems architecture when applied to
contemporary cloud-native applications. The challenges are manifold: consistency,
availability, partition tolerance - the classic CAP theorem constraints that
every architect must navigate with care and precision.

Furthermore, the human elements of software development - team dynamics, communication
patterns, and collaborative problem-solving - remain as crucial as ever. No amount
of technological advancement can substitute for clear thinking and effective teamwork.

EOF
        done
        PROMPT="Read $TEST_FILE and provide a detailed summary of each chapter. Continue until you've summarized all chapters or hit an error."
        ;;
    *)
        # Mixed content - read real codebase files
        PROMPT="List all TypeScript files in /home/jesse and read the first 10 you find. Analyze each one and explain what it does. Keep reading more files and analyzing until you hit an error."
        ;;
esac

log "Starting Claude session with prompt..."
log "Prompt: $PROMPT"
log ""

# Monitor in background
(
    while true; do
        SIZE=$(get_transcript_size)
        if [ "$SIZE" != "0" ] && [ -n "$SIZE" ]; then
            SIZE_MB=$(awk "BEGIN {printf \"%.2f\", $SIZE / 1048576}")
            echo "[$(date '+%H:%M:%S')] Transcript size: ${SIZE_MB}MB ($SIZE bytes)" >> "$LOG_FILE"
        fi
        sleep 10
    done
) &
MONITOR_PID=$!

cleanup() {
    kill $MONITOR_PID 2>/dev/null
    rm -rf "$TEST_DIR"

    # Get final size
    FINAL_SIZE=$(get_transcript_size)
    FINAL_MB=$(awk "BEGIN {printf \"%.2f\", $FINAL_SIZE / 1048576}")

    log ""
    log "=== Test Complete ==="
    log "Final transcript size: ${FINAL_MB}MB ($FINAL_SIZE bytes)"
    log "Content type: $CONTENT_TYPE"
    log ""

    # Append to results
    echo "{\"timestamp\": \"$(date -Iseconds)\", \"content_type\": \"$CONTENT_TYPE\", \"final_size_bytes\": $FINAL_SIZE, \"final_size_mb\": $FINAL_MB}" >> "$RESULTS_FILE"

    log "Results appended to $RESULTS_FILE"
}
trap cleanup EXIT

# Run Claude with the test prompt
# Using --dangerously-skip-permissions and piping to avoid interactive prompts
cd "$TEST_DIR"
timeout 7200 $CLAUDE_BIN --dangerously-skip-permissions "$PROMPT" 2>&1 | tee -a "$LOG_FILE"
EXIT_CODE=$?

log ""
log "Claude exited with code: $EXIT_CODE"
