#!/bin/bash
# =============================================================================
# Threshold Test Suite - Parallel waves with timeout
# =============================================================================
# Wave 1: Starts immediately (2 tests in parallel)
# Wave 2: Starts after 1 hour (2 tests in parallel)
# Each test: 45-minute timeout, separate directory, clean exit
#
# Usage: ./threshold-test-suite.sh
# Results: ~/.claude/threshold-tests/TIMESTAMP/summary.txt
# =============================================================================

set -e

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RESULTS_BASE="$HOME/.claude/threshold-tests/$TIMESTAMP"
LOG="$RESULTS_BASE/master.log"
SUMMARY="$RESULTS_BASE/summary.txt"
TEST_TIMEOUT=2700  # 45 minutes in seconds

# Find real claude binary (skip wrapper)
CLAUDE_BIN=""
for c in "$HOME/.local/bin/claude" "/usr/local/bin/claude" "/usr/bin/claude"; do
    [ -x "$c" ] && CLAUDE_BIN="$c" && break
done
[ -z "$CLAUDE_BIN" ] && { echo "ERROR: Claude not found"; exit 1; }

mkdir -p "$RESULTS_BASE"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"
}

# =============================================================================
# Run a single test in isolation
# =============================================================================
run_isolated_test() {
    local test_name=$1
    local test_prompt=$2
    local test_dir="$RESULTS_BASE/$test_name"
    local project_dir="$HOME/.claude-test-$test_name"  # Separate project dir!

    mkdir -p "$test_dir"
    mkdir -p "$project_dir"

    log "[$test_name] Starting test in isolated directory: $project_dir"

    # Create a marker file in the project dir
    echo "Threshold test: $test_name" > "$project_dir/TEST_MARKER.txt"
    echo "Started: $(date)" >> "$project_dir/TEST_MARKER.txt"

    # Monitor transcript size in background
    (
        sleep 5  # Wait for Claude to start
        while [ -f "$test_dir/.running" ]; do
            # Find newest transcript modified in last 5 min (more reliable)
            TRANSCRIPT=$(find ~/.claude/projects -name "*.jsonl" -mmin -5 -type f 2>/dev/null | grep -v subagents | xargs -r ls -t 2>/dev/null | head -1)
            if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
                SIZE=$(stat -c %s "$TRANSCRIPT" 2>/dev/null || echo 0)
                SIZE_KB=$((SIZE / 1024))
                echo "[$(date '+%H:%M:%S')] ${SIZE_KB}KB" >> "$test_dir/size.log"
            else
                echo "[$(date '+%H:%M:%S')] waiting..." >> "$test_dir/size.log"
            fi
            sleep 15
        done
    ) &
    MONITOR_PID=$!

    touch "$test_dir/.running"
    START_TIME=$(date +%s)

    # Run Claude with --print mode (runs in background, writes to file)
    cd "$project_dir"

    # Start Claude task and capture the task info
    TASK_OUTPUT=$($CLAUDE_BIN --print "$test_prompt" 2>&1)
    echo "$TASK_OUTPUT" > "$test_dir/task_start.log"

    # Extract task ID and output file
    TASK_ID=$(echo "$TASK_OUTPUT" | grep -oP 'ID: \K[a-f0-9]+' || echo "")
    TASK_FILE=$(echo "$TASK_OUTPUT" | grep -oP 'written to: \K[^\s]+' || echo "")

    if [ -z "$TASK_ID" ]; then
        log "[$test_name] ERROR: Failed to start Claude task"
        EXIT_CODE=1
    else
        log "[$test_name] Task started: $TASK_ID"

        # Wait for task to complete or timeout
        WAIT_START=$(date +%s)
        while [ $(($(date +%s) - WAIT_START)) -lt $TEST_TIMEOUT ]; do
            # Check if task output file exists and task is still running
            if [ -f "$TASK_FILE" ]; then
                # Check if task completed (look for completion markers)
                if grep -q "completed\|error\|LIMIT REACHED" "$TASK_FILE" 2>/dev/null; then
                    break
                fi
            fi
            sleep 10
        done

        # Copy task output
        [ -f "$TASK_FILE" ] && cp "$TASK_FILE" "$test_dir/output.log"
        EXIT_CODE=0
    fi

    END_TIME=$(date +%s)
    rm -f "$test_dir/.running"

    # Give monitor time to catch final size
    sleep 2
    kill $MONITOR_PID 2>/dev/null || true

    DURATION=$((END_TIME - START_TIME))
    FINAL_SIZE=$(tail -1 "$test_dir/size.log" 2>/dev/null | awk '{print $2}' || echo "unknown")

    # Determine failure reason
    if [ $EXIT_CODE -eq 124 ]; then
        FAIL_REASON="timeout"
    elif [ $EXIT_CODE -eq 0 ]; then
        FAIL_REASON="clean_exit"
    else
        FAIL_REASON="error_$EXIT_CODE"
    fi

    # Save results
    cat > "$test_dir/results.json" << EOF
{
    "test_name": "$test_name",
    "timestamp": "$TIMESTAMP",
    "exit_code": $EXIT_CODE,
    "fail_reason": "$FAIL_REASON",
    "final_size": "$FINAL_SIZE",
    "duration_seconds": $DURATION,
    "project_dir": "$project_dir"
}
EOF

    log "[$test_name] Completed: exit=$EXIT_CODE ($FAIL_REASON), size=$FINAL_SIZE, duration=${DURATION}s"

    # Cleanup test project dir
    rm -rf "$project_dir"

    return $EXIT_CODE
}

# =============================================================================
# Test Prompts - designed to inflate context predictably
# =============================================================================

PROMPT_CODE='CONTEXT TEST: Read code files continuously. Find ts/js/py files in /home/jesse, read each one, write analysis. Never stop. Keep reading more files until error.'

PROMPT_PROSE='CONTEXT TEST: Write documentation continuously. Topics: microservices, databases, APIs, kubernetes. Write 500+ words each. Never stop. Keep writing until error.'

PROMPT_TOOLS='CONTEXT TEST: Run commands continuously. Run: ls -laR, find, ps, df, grep. Analyze output. Never stop. Keep running commands until error.'

PROMPT_MIXED='CONTEXT TEST: Mixed mode. Cycle: read 3 files, write analysis, run 5 commands, write docs. Repeat forever. Never stop until error.'

# =============================================================================
# Main Execution
# =============================================================================

log "=============================================="
log "THRESHOLD TEST SUITE STARTED"
log "=============================================="
log "Timestamp: $TIMESTAMP"
log "Results: $RESULTS_BASE"
log "Test timeout: ${TEST_TIMEOUT}s (45 min)"
log ""

# Wave 1: Start 2 tests in parallel (code + prose)
log "=== WAVE 1: Starting code + prose tests ==="

run_isolated_test "code" "$PROMPT_CODE" &
PID_CODE=$!
log "Started code test (PID: $PID_CODE)"

run_isolated_test "prose" "$PROMPT_PROSE" &
PID_PROSE=$!
log "Started prose test (PID: $PID_PROSE)"

log ""
log "Wave 1 running. Wave 2 starts in 60 minutes..."
log ""

# Wait 60 minutes for Wave 2
sleep 3600

log "=== WAVE 2: Starting tools + mixed tests ==="

run_isolated_test "tools" "$PROMPT_TOOLS" &
PID_TOOLS=$!
log "Started tools test (PID: $PID_TOOLS)"

run_isolated_test "mixed" "$PROMPT_MIXED" &
PID_MIXED=$!
log "Started mixed test (PID: $PID_MIXED)"

# Wait for all tests to complete
log ""
log "Waiting for all tests to complete..."
wait $PID_CODE 2>/dev/null || true
wait $PID_PROSE 2>/dev/null || true
wait $PID_TOOLS 2>/dev/null || true
wait $PID_MIXED 2>/dev/null || true

log ""
log "=============================================="
log "ALL TESTS COMPLETE"
log "=============================================="

# Generate summary
cat > "$SUMMARY" << 'HEADER'
# Threshold Test Results Summary
# Generated by threshold-test-suite.sh

HEADER

echo "Timestamp: $TIMESTAMP" >> "$SUMMARY"
echo "Test Timeout: ${TEST_TIMEOUT}s" >> "$SUMMARY"
echo "" >> "$SUMMARY"
echo "## Results by Test" >> "$SUMMARY"
echo "" >> "$SUMMARY"

for test_name in code prose tools mixed; do
    RESULT_FILE="$RESULTS_BASE/$test_name/results.json"
    if [ -f "$RESULT_FILE" ]; then
        echo "### $test_name" >> "$SUMMARY"
        cat "$RESULT_FILE" >> "$SUMMARY"
        echo "" >> "$SUMMARY"

        # Add last few size readings
        echo "Size progression (last 10):" >> "$SUMMARY"
        tail -10 "$RESULTS_BASE/$test_name/size.log" 2>/dev/null >> "$SUMMARY" || echo "No size log" >> "$SUMMARY"
        echo "" >> "$SUMMARY"
    fi
done

# Calculate recommended thresholds
echo "## Threshold Analysis" >> "$SUMMARY"
echo "" >> "$SUMMARY"
echo "Sizes at failure/timeout:" >> "$SUMMARY"

MIN_SIZE=999999
for test_name in code prose tools mixed; do
    SIZE_FILE="$RESULTS_BASE/$test_name/size.log"
    if [ -f "$SIZE_FILE" ]; then
        FINAL=$(tail -1 "$SIZE_FILE" | awk '{print $2}' | tr -d 'KB')
        if [ -n "$FINAL" ] && [ "$FINAL" -lt "$MIN_SIZE" ] 2>/dev/null; then
            MIN_SIZE=$FINAL
        fi
        echo "  $test_name: ${FINAL}KB" >> "$SUMMARY"
    fi
done

echo "" >> "$SUMMARY"
if [ "$MIN_SIZE" != "999999" ]; then
    CRITICAL=$((MIN_SIZE * 80 / 100))  # 80% of minimum
    WARN=$((CRITICAL - 200))
    EARLY=$((WARN - 200))

    echo "Recommended thresholds (based on minimum with 20% safety margin):" >> "$SUMMARY"
    echo "  EARLY_WARN: ${EARLY}KB" >> "$SUMMARY"
    echo "  WARN: ${WARN}KB" >> "$SUMMARY"
    echo "  CRITICAL: ${CRITICAL}KB" >> "$SUMMARY"
fi

echo "" >> "$SUMMARY"
echo "## Files to Update" >> "$SUMMARY"
echo "- ~/.claude/hooks/context-monitor.sh" >> "$SUMMARY"
echo "- ~/claude-auto-handoff/hooks/context-monitor.sh" >> "$SUMMARY"
echo "- ~/claude-auto-handoff/README.md" >> "$SUMMARY"
echo "- ~/CLAUDE.md" >> "$SUMMARY"
echo "- GitHub issue #18417 comment" >> "$SUMMARY"

log ""
log "Summary written to: $SUMMARY"
log ""
cat "$SUMMARY"
