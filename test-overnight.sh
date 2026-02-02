#!/bin/bash
# Overnight Threshold Test Suite
# Runs multiple Claude sessions in parallel with different content types
# Uses tmux for session management
#
# Usage: ./test-overnight.sh
# Check results: ./test-overnight.sh results

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="$HOME/.claude/threshold-tests"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

# Find real claude binary
CLAUDE_BIN=""
for c in "$HOME/.local/bin/claude" "/usr/local/bin/claude" "/usr/bin/claude"; do
    [ -x "$c" ] && CLAUDE_BIN="$c" && break
done
[ -z "$CLAUDE_BIN" ] && CLAUDE_BIN=$(which claude)

mkdir -p "$RESULTS_DIR"

# Test configurations
declare -A TESTS
TESTS["code"]="You are testing context limits. Read TypeScript files from /home/jesse and analyze each one in detail. Start with: find /home/jesse -name '*.ts' -o -name '*.tsx' 2>/dev/null | grep -v node_modules | head -50. Then read and analyze each file thoroughly. Keep going until you hit an error or context limit. Do not stop until forced to."

TESTS["prose"]="You are testing context limits. Write a detailed technical document about software architecture patterns. Cover: microservices, event sourcing, CQRS, DDD, hexagonal architecture, clean architecture. For each pattern, write at least 500 words explaining concepts, trade-offs, and implementation details. Keep writing until you hit an error or context limit. Do not stop until forced to."

TESTS["tools"]="You are testing context limits. Run many small bash commands to gather system information. Check disk usage, list directories, read small config files, check processes. Run at least 100 different commands, logging output for each. Keep going until you hit an error or context limit. Do not stop until forced to."

# Function to run a single test
run_test() {
    local test_name=$1
    local test_prompt=$2
    local test_dir="$RESULTS_DIR/$TIMESTAMP-$test_name"
    local log_file="$test_dir/session.log"
    local size_log="$test_dir/size.log"

    mkdir -p "$test_dir"

    echo "Starting test: $test_name"
    echo "Log: $log_file"

    # Start size monitor for this test
    (
        while true; do
            # Find the newest transcript
            TRANSCRIPT=$(find ~/.claude/projects -name "*.jsonl" -mmin -5 -type f 2>/dev/null | \
                grep -v subagents | xargs -r ls -t 2>/dev/null | head -1)
            if [ -n "$TRANSCRIPT" ]; then
                SIZE=$(stat -c %s "$TRANSCRIPT" 2>/dev/null || echo 0)
                echo "[$(date '+%H:%M:%S')] $SIZE bytes - $TRANSCRIPT" >> "$size_log"
            fi
            sleep 15
        done
    ) &
    local monitor_pid=$!
    echo $monitor_pid > "$test_dir/monitor.pid"

    # Run Claude with the test prompt
    cd "$test_dir"
    timeout 7200 $CLAUDE_BIN --dangerously-skip-permissions "$test_prompt" > "$log_file" 2>&1
    local exit_code=$?

    # Stop monitor
    kill $monitor_pid 2>/dev/null

    # Record results
    local final_size=$(tail -1 "$size_log" 2>/dev/null | awk '{print $2}' || echo "unknown")
    cat > "$test_dir/results.json" << EOF
{
    "test_name": "$test_name",
    "timestamp": "$TIMESTAMP",
    "exit_code": $exit_code,
    "final_size_bytes": "$final_size",
    "log_file": "$log_file",
    "size_log": "$size_log"
}
EOF

    echo "Test $test_name completed. Exit code: $exit_code, Final size: $final_size"
}

# Show results
show_results() {
    echo "=== Test Results ==="
    echo ""
    for dir in "$RESULTS_DIR"/*/; do
        if [ -f "$dir/results.json" ]; then
            echo "--- $(basename "$dir") ---"
            cat "$dir/results.json"
            echo ""
            echo "Last 5 size entries:"
            tail -5 "$dir/size.log" 2>/dev/null || echo "No size log"
            echo ""
        fi
    done
}

# Main
case "${1:-run}" in
    results)
        show_results
        ;;
    run)
        # Check for tmux
        if ! command -v tmux &>/dev/null; then
            echo "ERROR: tmux required for parallel tests"
            echo "Install: sudo apt install tmux"
            exit 1
        fi

        echo "=== Overnight Threshold Test Suite ==="
        echo "Timestamp: $TIMESTAMP"
        echo "Results dir: $RESULTS_DIR"
        echo ""

        # Kill any existing test sessions
        tmux kill-session -t threshold-code 2>/dev/null || true
        tmux kill-session -t threshold-prose 2>/dev/null || true
        tmux kill-session -t threshold-tools 2>/dev/null || true

        # Start tests in tmux sessions
        echo "Starting parallel tests in tmux..."

        for test_name in "${!TESTS[@]}"; do
            echo "  Starting: $test_name"
            tmux new-session -d -s "threshold-$test_name" \
                "cd '$SCRIPT_DIR' && ./test-overnight.sh single $test_name '${TESTS[$test_name]}'"
            sleep 2
        done

        echo ""
        echo "Tests running in background tmux sessions:"
        echo "  tmux attach -t threshold-code"
        echo "  tmux attach -t threshold-prose"
        echo "  tmux attach -t threshold-tools"
        echo ""
        echo "Check results in morning:"
        echo "  $0 results"
        echo ""
        echo "Or monitor live:"
        echo "  watch -n 5 'tail -3 $RESULTS_DIR/$TIMESTAMP-*/size.log'"
        ;;
    single)
        # Run a single test (called by tmux)
        test_name=$2
        test_prompt=$3
        run_test "$test_name" "$test_prompt"
        echo "Press Enter to close this tmux session..."
        read
        ;;
    *)
        echo "Usage: $0 [run|results|single]"
        ;;
esac
