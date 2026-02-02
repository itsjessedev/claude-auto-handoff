#!/bin/bash
# =============================================================================
# Master Runner - Autonomous Threshold Testing & Analysis
# =============================================================================
# This script runs everything:
# 1. Threshold tests (3 conversation types)
# 2. Analysis of results
# 3. System updates
# 4. Documentation updates
# 5. Repo sync
#
# Run with: nohup ./run-autonomous-suite.sh > /tmp/threshold-suite.log 2>&1 &
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULTS_DIR="$HOME/.claude/threshold-results"
LOG_FILE="$RESULTS_DIR/autonomous-suite.log"

mkdir -p "$RESULTS_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

log "=============================================="
log "  AUTONOMOUS THRESHOLD SUITE STARTING"
log "=============================================="

# Make scripts executable
chmod +x "$SCRIPT_DIR/autonomous-threshold-test.sh"
chmod +x "$SCRIPT_DIR/analyze-thresholds.sh"

# Run threshold tests
log "PHASE 1: Running threshold tests..."
"$SCRIPT_DIR/autonomous-threshold-test.sh" 2>&1 | tee -a "$LOG_FILE"
TEST_EXIT=$?

if [ $TEST_EXIT -ne 0 ]; then
    log "WARNING: Test suite exited with code $TEST_EXIT"
    log "Attempting to continue with available data..."
fi

# Check if we have any results
if [ ! -d "$RESULTS_DIR" ] || [ -z "$(ls $RESULTS_DIR/*.md 2>/dev/null)" ]; then
    log "ERROR: No test results found. Cannot proceed."
    exit 1
fi

# Run analysis
log ""
log "PHASE 2: Analyzing results..."
"$SCRIPT_DIR/analyze-thresholds.sh" 2>&1 | tee -a "$LOG_FILE"

# Verify completion
if [ -f "$RESULTS_DIR/READY_FOR_E2E_TEST.md" ]; then
    log ""
    log "=============================================="
    log "  AUTONOMOUS SUITE COMPLETED SUCCESSFULLY"
    log "=============================================="
    log ""
    log "Results: $RESULTS_DIR/"
    log "Ready for E2E test: $RESULTS_DIR/READY_FOR_E2E_TEST.md"
    log ""
    log "Awaiting Jesse's return for final E2E testing."
else
    log ""
    log "=============================================="
    log "  SUITE COMPLETED WITH ISSUES"
    log "=============================================="
    log "Check logs for details: $LOG_FILE"
fi
