#!/bin/bash
# Wrapper to run overnight test in tmux and signal when done

TMUX_SESSION="threshold-test"

# Kill any existing session
tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true

# Create signal file indicating test is running
echo "RUNNING since $(date)" > ~/.claude/.threshold-test-status

# Start test in tmux
tmux new-session -d -s "$TMUX_SESSION" "
    ~/claude-auto-handoff/overnight-threshold-test.sh
    echo 'COMPLETE at $(date)' > ~/.claude/.threshold-test-status
    echo 'Test complete. Results in ~/.claude/threshold-test-results.md'
    sleep 3600  # Keep tmux alive for review
"

echo "=============================================="
echo "OVERNIGHT TEST STARTED"
echo "=============================================="
echo ""
echo "Test running in tmux session: $TMUX_SESSION"
echo ""
echo "Commands:"
echo "  tmux attach -t $TMUX_SESSION   # Watch live"
echo "  tmux kill-session -t $TMUX_SESSION  # Stop test"
echo ""
echo "Results will be in: ~/.claude/threshold-test-results.md"
echo ""
echo "When you wake up, just send a message in your Claude chat."
echo "Claude will check the results and update thresholds."
echo "=============================================="
