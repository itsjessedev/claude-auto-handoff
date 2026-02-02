#!/bin/bash
# Serial Threshold Tests - Run one test at a time overnight
# Cheaper than parallel, still gets all data points
#
# Usage: ./test-serial.sh [code|prose|tools|all]

set -e

RESULTS_DIR="$HOME/.claude/threshold-tests"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
LOG="$RESULTS_DIR/serial-$TIMESTAMP.log"

mkdir -p "$RESULTS_DIR"

# Find claude binary (not wrapper, to avoid wrapper's restart logic interfering)
CLAUDE_BIN=""
for c in "$HOME/.local/bin/claude" "/usr/local/bin/claude" "/usr/bin/claude"; do
    [ -x "$c" ] && CLAUDE_BIN="$c" && break
done
[ -z "$CLAUDE_BIN" ] && CLAUDE_BIN=$(which claude)

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"
}

monitor_and_run() {
    local test_name=$1
    local prompt=$2
    local test_dir="$RESULTS_DIR/$TIMESTAMP-$test_name"
    local size_log="$test_dir/size.log"

    mkdir -p "$test_dir"
    log "=== Starting test: $test_name ==="

    # Start size monitor
    (
        while [ -f "$test_dir/.running" ]; do
            TRANSCRIPT=$(find ~/.claude/projects -name "*.jsonl" -mmin -5 -type f 2>/dev/null | \
                grep -v subagents | xargs -r ls -t 2>/dev/null | head -1)
            if [ -n "$TRANSCRIPT" ]; then
                SIZE=$(stat -c %s "$TRANSCRIPT" 2>/dev/null || echo 0)
                SIZE_KB=$((SIZE / 1024))
                echo "[$(date '+%H:%M:%S')] ${SIZE_KB}KB" >> "$size_log"
            fi
            sleep 10
        done
    ) &
    MONITOR_PID=$!

    touch "$test_dir/.running"

    # Run test
    START_TIME=$(date +%s)
    timeout 3600 $CLAUDE_BIN --dangerously-skip-permissions "$prompt" > "$test_dir/output.log" 2>&1
    EXIT_CODE=$?
    END_TIME=$(date +%s)

    rm -f "$test_dir/.running"
    kill $MONITOR_PID 2>/dev/null || true
    sleep 2

    # Get final size
    FINAL_SIZE=$(tail -1 "$size_log" 2>/dev/null | awk '{print $2}' | tr -d 'KB' || echo "unknown")
    DURATION=$((END_TIME - START_TIME))

    # Save results
    cat > "$test_dir/results.txt" << EOF
Test: $test_name
Timestamp: $TIMESTAMP
Exit Code: $EXIT_CODE
Final Size: ${FINAL_SIZE}KB
Duration: ${DURATION}s
EOF

    log "Test $test_name completed: exit=$EXIT_CODE, size=${FINAL_SIZE}KB, duration=${DURATION}s"
    log ""

    # Brief pause between tests
    sleep 10
}

# Test prompts (shorter, more focused)
PROMPT_CODE="Context limit test - CODE. Read TypeScript files: run 'find /home/jesse -name \"*.ts\" 2>/dev/null | grep -v node_modules | head -30', then read and analyze each file in detail. Keep reading more files until you hit an error. Do not stop voluntarily."

PROMPT_PROSE="Context limit test - PROSE. Write an extensive technical document about distributed systems. Cover: CAP theorem, consensus algorithms (Paxos, Raft), eventual consistency, CRDTs, vector clocks, gossip protocols. Write at least 300 words per topic. Keep writing until you hit an error. Do not stop voluntarily."

PROMPT_TOOLS="Context limit test - TOOLS. Run many bash commands to explore the system. Check disk usage, memory, processes, list directories, read config files. Run at least 50 different commands with varied outputs. Keep running commands until you hit an error. Do not stop voluntarily."

case "${1:-all}" in
    code)
        monitor_and_run "code" "$PROMPT_CODE"
        ;;
    prose)
        monitor_and_run "prose" "$PROMPT_PROSE"
        ;;
    tools)
        monitor_and_run "tools" "$PROMPT_TOOLS"
        ;;
    all)
        log "=== SERIAL TEST SUITE STARTING ==="
        log "Running all 3 tests sequentially"
        log "Estimated time: 2-4 hours total"
        log ""

        monitor_and_run "code" "$PROMPT_CODE"
        monitor_and_run "prose" "$PROMPT_PROSE"
        monitor_and_run "tools" "$PROMPT_TOOLS"

        log "=== ALL TESTS COMPLETE ==="
        log "Results in: $RESULTS_DIR/$TIMESTAMP-*/"
        log ""
        log "Summary:"
        for dir in "$RESULTS_DIR/$TIMESTAMP"-*/; do
            [ -f "$dir/results.txt" ] && cat "$dir/results.txt" && echo ""
        done
        ;;
    *)
        echo "Usage: $0 [code|prose|tools|all]"
        echo ""
        echo "  code  - Test with TypeScript file reading"
        echo "  prose - Test with documentation writing"
        echo "  tools - Test with many bash commands"
        echo "  all   - Run all 3 serially (recommended overnight)"
        ;;
esac
