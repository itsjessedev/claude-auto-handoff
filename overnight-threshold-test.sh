#!/bin/bash
# =============================================================================
# Overnight Threshold Test - Automated using expect
# =============================================================================
# Runs Claude in an automated session, inflates context until it hits the limit,
# and logs size data points throughout.
#
# Usage: ./overnight-threshold-test.sh
# Results: ~/.claude/threshold-test-results.md
# =============================================================================

set -e

RESULTS_FILE="$HOME/.claude/threshold-test-results.md"
LOG_FILE="$HOME/.claude/threshold-test.log"
EXPECT_SCRIPT="/tmp/claude-threshold-test.exp"

# Create isolated test directory to get a dedicated transcript
TEST_PROJECT_DIR="$HOME/.claude-threshold-test-$$"
mkdir -p "$TEST_PROJECT_DIR"
echo "# Threshold Test Project" > "$TEST_PROJECT_DIR/README.md"

# Find Claude binary - use the actual binary, not wrapper
CLAUDE_BIN="$HOME/.local/bin/claude"
[ ! -x "$CLAUDE_BIN" ] && { echo "ERROR: Claude not found at $CLAUDE_BIN"; exit 1; }

# Cleanup function
cleanup() {
    rm -rf "$TEST_PROJECT_DIR" 2>/dev/null || true
}
trap cleanup EXIT

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# Initialize results file
cat > "$RESULTS_FILE" << 'EOF'
# Overnight Threshold Test Results

**Status:** RUNNING
**Started:** TIMESTAMP_PLACEHOLDER

## Data Points

| Time | Size (KB) | Notes |
|------|-----------|-------|
EOF
sed -i "s/TIMESTAMP_PLACEHOLDER/$(date '+%Y-%m-%d %H:%M:%S')/" "$RESULTS_FILE"

log "=== Starting Overnight Threshold Test ==="

# CRITICAL: Verify auto-compact is disabled globally
if grep -q '"autoCompactEnabled": false' ~/.claude.json 2>/dev/null; then
    log "✓ Auto-compact is disabled globally"
else
    log "ERROR: Auto-compact is NOT disabled in ~/.claude.json!"
    log "Run Claude, use /config to disable auto-compact, then re-run this test."
    exit 1
fi

# Create the expect script
cat > "$EXPECT_SCRIPT" << 'EXPECT_EOF'
#!/usr/bin/expect -f

# Configuration
set timeout 300
set claude_bin [lindex $argv 0]
set log_file [lindex $argv 1]
set results_file [lindex $argv 2]
set test_project_dir [lindex $argv 3]

# Helper to log
proc log {msg} {
    global log_file
    set ts [clock format [clock seconds] -format "%Y-%m-%d %H:%M:%S"]
    set fd [open $log_file a]
    puts $fd "\[$ts\] $msg"
    close $fd
}

# Helper to get transcript size - looks for this test's specific project
proc get_transcript_size {} {
    global test_project_dir
    # Convert project dir to Claude's path format (/ becomes -)
    set project_path [string map {"/" "-"} $test_project_dir]
    set result [exec bash -c "
        find ~/.claude/projects -path '*$project_path*' -name '*.jsonl' -type f 2>/dev/null | \
        grep -v subagents | xargs -r ls -t 2>/dev/null | head -1 | \
        xargs -r stat -c %s 2>/dev/null || echo 0
    "]
    return [expr {$result / 1024}]
}

# Helper to log data point
proc log_datapoint {size_kb note} {
    global results_file
    set ts [clock format [clock seconds] -format "%H:%M:%S"]
    set fd [open $results_file a]
    puts $fd "| $ts | $size_kb | $note |"
    close $fd
}

# Prompts to inflate context
set prompts {
    "Read all .md files in /home/jesse and summarize each one in detail. Use the Read tool."
    "Now read all .ts and .tsx files in /home/jesse/itsjesse.dev if it exists. Analyze the code patterns."
    "Write a comprehensive 2000-word guide on microservices architecture including code examples."
    "Read any Python files in /home/jesse and explain what each one does in detail."
    "Write detailed documentation about event-driven systems, CQRS, and event sourcing with examples."
    "Search for and read any configuration files (*.json, *.yaml, *.toml) in /home/jesse."
    "Write a 1500-word tutorial on database optimization strategies with SQL examples."
    "Read shell scripts in /home/jesse and explain each one."
    "Write comprehensive API documentation for a fictional e-commerce platform."
    "Explain Kubernetes concepts in detail with YAML examples for deployments, services, and ingress."
}

log "Starting Claude session in isolated project: $test_project_dir"

# Start Claude in the isolated test directory
cd $test_project_dir
spawn $claude_bin --dangerously-skip-permissions

# Wait for initial prompt
expect {
    -re ".*❯.*" { log "Claude ready" }
    timeout { log "Timeout waiting for Claude"; exit 1 }
    eof { log "Claude exited unexpectedly"; exit 1 }
}

# Note: auto-compact is globally disabled in ~/.claude.json (autoCompactEnabled: false)
# No need to use /config menu - it's already off

set last_size 0
set prompt_idx 0
set max_prompts [llength $prompts]

# Main loop - keep sending prompts until we hit the limit
while {1} {
    # Get current size
    set current_size [get_transcript_size]

    # Log if size changed significantly
    if {$current_size > $last_size + 50} {
        log "Size: ${current_size}KB"
        log_datapoint $current_size "Growing"
        set last_size $current_size
    }

    # Check for context warning indicators in output
    # (Claude Code shows "Context low" messages)

    # Send next prompt
    set prompt [lindex $prompts [expr {$prompt_idx % $max_prompts}]]
    incr prompt_idx

    log "Sending prompt #$prompt_idx"
    send "$prompt\r"

    # Wait for response with longer timeout
    set response_complete 0
    expect {
        -re "Context low.*remaining" {
            set pct [regexp -inline {\d+%} $expect_out(buffer)]
            log "CONTEXT WARNING: $pct remaining"
            log_datapoint $current_size "Context warning: $pct remaining"
            exp_continue
        }
        -re ".*❯.*" {
            log "Response complete"
            set response_complete 1
        }
        -re "error|Error|ERROR" {
            log "Error detected in output"
            log_datapoint $current_size "Error detected"
        }
        timeout {
            log "Response timeout - may have hit limit"
            log_datapoint [get_transcript_size] "Timeout"
            break
        }
        eof {
            log "Claude session ended"
            log_datapoint [get_transcript_size] "Session ended"
            break
        }
    }

    # Brief pause between prompts
    sleep 2

    # Safety: stop after many prompts (should hit limit before this)
    if {$prompt_idx > 100} {
        log "Reached prompt limit without hitting context limit"
        break
    }
}

# Final size reading
set final_size [get_transcript_size]
log "Final size: ${final_size}KB"
log_datapoint $final_size "FINAL"

log "Test complete"
EXPECT_EOF

chmod +x "$EXPECT_SCRIPT"

# Run the expect script
log "Launching expect script"
log "Test project directory: $TEST_PROJECT_DIR"
expect "$EXPECT_SCRIPT" "$CLAUDE_BIN" "$LOG_FILE" "$RESULTS_FILE" "$TEST_PROJECT_DIR" 2>&1 | tee -a "$LOG_FILE"

# Finalize results
cat >> "$RESULTS_FILE" << EOF

## Summary

**Status:** COMPLETED
**Finished:** $(date '+%Y-%m-%d %H:%M:%S')

### Analysis

EOF

# Extract key findings
FINAL_SIZE=$(grep "FINAL" "$RESULTS_FILE" | tail -1 | awk -F'|' '{print $3}' | tr -d ' ')
WARNING_SIZE=$(grep "Context warning" "$RESULTS_FILE" | head -1 | awk -F'|' '{print $3}' | tr -d ' ')

if [ -n "$FINAL_SIZE" ]; then
    echo "- **Final transcript size:** ${FINAL_SIZE}KB" >> "$RESULTS_FILE"
fi
if [ -n "$WARNING_SIZE" ]; then
    echo "- **Size at first warning:** ${WARNING_SIZE}KB" >> "$RESULTS_FILE"
fi

cat >> "$RESULTS_FILE" << 'EOF'

### Recommended Thresholds

Based on this test (will be filled in by Claude):
- EARLY_WARN: TBD
- WARN: TBD
- CRITICAL: TBD

### Files to Update

- [ ] ~/.claude/hooks/context-monitor.sh
- [ ] ~/claude-auto-handoff/hooks/context-monitor.sh
- [ ] ~/claude-auto-handoff/README.md
- [ ] ~/CLAUDE.md
- [ ] GitHub issue #18417
EOF

log "Results written to $RESULTS_FILE"
echo ""
echo "=============================================="
echo "TEST COMPLETE"
echo "Results: $RESULTS_FILE"
echo "Log: $LOG_FILE"
echo "=============================================="
