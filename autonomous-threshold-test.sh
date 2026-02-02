#!/bin/bash
# =============================================================================
# Autonomous Threshold Test Suite
# =============================================================================
# Runs multiple conversation types to find safe context thresholds.
# Simplified version - more robust transcript detection.
# =============================================================================

set -e

RESULTS_DIR="$HOME/threshold-test-results"
LOG_FILE="$RESULTS_DIR/master.log"
CLAUDE_BIN="$HOME/.local/bin/claude"
STATUS_FILE="$RESULTS_DIR/status.txt"

mkdir -p "$RESULTS_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# Verify prerequisites
if [ ! -x "$CLAUDE_BIN" ]; then
    echo "ERROR: Claude not found at $CLAUDE_BIN"
    exit 1
fi

if ! grep -q '"autoCompactEnabled": false' ~/.claude.json 2>/dev/null; then
    echo "ERROR: Auto-compact must be disabled in ~/.claude.json"
    exit 1
fi

echo "RUNNING" > "$STATUS_FILE"
log "=== Autonomous Threshold Test Suite Started ==="
log "Results directory: $RESULTS_DIR"

# Generic test runner
run_test() {
    local TEST_NAME="$1"
    shift
    local PROMPTS=("$@")

    local TEST_DIR="$HOME/threshold-test-$TEST_NAME-$$"
    local RESULT_FILE="$RESULTS_DIR/${TEST_NAME}.md"
    local EXPECT_SCRIPT="/tmp/test-${TEST_NAME}-$$.exp"

    log "--- Starting $TEST_NAME test ---"
    mkdir -p "$TEST_DIR"
    echo "# Threshold Test: $TEST_NAME" > "$TEST_DIR/README.md"

    cat > "$RESULT_FILE" << EOF
# Threshold Test: $TEST_NAME

**Started:** $(date '+%Y-%m-%d %H:%M:%S')

## Data Points

| Time | Size (KB) | Context % | Notes |
|------|-----------|-----------|-------|
EOF

    # Build prompts TCL list
    local PROMPTS_TCL=""
    for p in "${PROMPTS[@]}"; do
        PROMPTS_TCL="$PROMPTS_TCL \"$p\""
    done

    cat > "$EXPECT_SCRIPT" << EXPECT_EOF
#!/usr/bin/expect -f
set timeout 300
set claude_bin "$CLAUDE_BIN"
set result_file "$RESULT_FILE"
set test_dir "$TEST_DIR"

proc log_data {size pct note} {
    global result_file
    set ts [clock format [clock seconds] -format "%H:%M:%S"]
    set fd [open \$result_file a]
    puts \$fd "| \$ts | \$size | \$pct | \$note |"
    close \$fd
}

proc get_size {} {
    # Find the newest transcript by sorting all jsonl files
    set result [exec bash -c {
        ls -t ~/.claude/projects/*/*.jsonl 2>/dev/null | head -1 | xargs -r stat -c %s 2>/dev/null || echo 0
    }]
    return [expr {\$result / 1024}]
}

cd \$test_dir
spawn \$claude_bin --dangerously-skip-permissions

# Wait for prompt (may take a while on first load)
expect {
    -re "❯" { }
    -re ">" { }
    timeout {
        log_data 0 "?" "TIMEOUT waiting for prompt"
        exit 1
    }
}

set prompts [list $PROMPTS_TCL]

set idx 0
set last_size 0

foreach prompt \$prompts {
    # Get size before sending
    set size [get_size]
    if {\$size > \$last_size + 20} {
        log_data \$size "?" "Before prompt \$idx"
        set last_size \$size
    }

    send "\$prompt\r"

    # Wait for response
    expect {
        -re {Context:?\s*(\d+)%} {
            set pct \$expect_out(1,string)
            log_data [get_size] \$pct "Context warning"
            exp_continue
        }
        -re {context.*(\d+)%} {
            set pct \$expect_out(1,string)
            log_data [get_size] \$pct "Context mention"
            exp_continue
        }
        -re "❯" {
            set size [get_size]
            log_data \$size "?" "After prompt \$idx"
            set last_size \$size
        }
        -re ">" { }
        timeout {
            log_data [get_size] "?" "TIMEOUT on prompt \$idx"
            break
        }
        eof {
            log_data [get_size] "?" "SESSION_END"
            break
        }
    }

    incr idx
    after 2000
}

set final [get_size]
log_data \$final "?" "FINAL"

# Try to exit cleanly
send "/exit\r"
expect {
    eof { }
    timeout { }
}
EXPECT_EOF

    chmod +x "$EXPECT_SCRIPT"

    # Run with timeout to prevent hanging
    timeout 1800 expect "$EXPECT_SCRIPT" 2>&1 | tee -a "$LOG_FILE" || {
        log "Test $TEST_NAME ended (timeout or completion)"
    }

    echo "" >> "$RESULT_FILE"
    echo "**Completed:** $(date '+%Y-%m-%d %H:%M:%S')" >> "$RESULT_FILE"

    rm -rf "$TEST_DIR"
    rm -f "$EXPECT_SCRIPT"
    log "--- $TEST_NAME test complete ---"
}

# =============================================================================
# Test 1: Read-Heavy
# =============================================================================
log "Running test 1/3: read-heavy"
run_test "read-heavy" \
    "Read all files in ~/.claude/hooks/ and explain each one in detail" \
    "Read ~/.claude/CRITICAL-RULES.md and summarize it completely" \
    "Read ~/.claude/system-context.md and list all the information" \
    "Find and read all shell scripts in ~/infrastructure/bin/ and document each" \
    "Read the contents of ~/claude-auto-handoff/hooks/ and explain the architecture" \
    "Search for all markdown files in ~/.claude/ and summarize each one"

# =============================================================================
# Test 2: Write-Heavy
# =============================================================================
log "Running test 2/3: write-heavy"
run_test "write-heavy" \
    "Write a complete REST API specification for an e-commerce platform with all endpoints documented" \
    "Write a comprehensive 2000-word guide on microservices architecture with code examples" \
    "Create detailed documentation for a CI/CD pipeline with GitHub Actions YAML examples" \
    "Write a full technical design document for a real-time chat application" \
    "Generate complete API documentation for a user authentication system with code samples"

# =============================================================================
# Test 3: Mixed
# =============================================================================
log "Running test 3/3: mixed"
run_test "mixed" \
    "Create a new file src/utils.ts with common utility functions" \
    "Read the file you just created and add error handling" \
    "Write unit tests for the utils file" \
    "Create src/api.ts with fetch wrapper functions" \
    "Read both files and refactor to share common code" \
    "Add comprehensive documentation to all functions"

# =============================================================================
# Finalize
# =============================================================================

echo "COMPLETED" > "$STATUS_FILE"
log "=== All tests completed ==="

# Create summary
cat > "$RESULTS_DIR/summary.md" << EOF
# Threshold Test Summary

**Completed:** $(date '+%Y-%m-%d %H:%M:%S')

## Tests Run

1. **read-heavy** - File reads, code analysis
2. **write-heavy** - Code generation, documentation
3. **mixed** - Typical development workflow

## Results Files

- $RESULTS_DIR/read-heavy.md
- $RESULTS_DIR/write-heavy.md
- $RESULTS_DIR/mixed.md
- $RESULTS_DIR/master.log

## Next Steps

Run the analysis script:
\`\`\`bash
~/claude-auto-handoff/analyze-thresholds.sh
\`\`\`
EOF

log "Summary written to $RESULTS_DIR/summary.md"
