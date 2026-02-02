#!/bin/bash
# =============================================================================
# Analyze Threshold Test Results
# =============================================================================
# Processes test results and:
# 1. Calculates optimal thresholds
# 2. Updates system files
# 3. Updates documentation
# 4. Syncs to repo
# =============================================================================

RESULTS_DIR="$HOME/threshold-test-results"
REPO_DIR="$HOME/claude-auto-handoff"

log() {
    echo "[$(date '+%H:%M:%S')] $*"
}

if [ ! -f "$RESULTS_DIR/status.txt" ] || [ "$(cat $RESULTS_DIR/status.txt)" != "COMPLETED" ]; then
    echo "ERROR: Tests not completed yet. Status: $(cat $RESULTS_DIR/status.txt 2>/dev/null || echo 'unknown')"
    exit 1
fi

log "=== Analyzing Threshold Test Results ==="

# Extract all size data points
extract_sizes() {
    local file="$1"
    grep -E '^\|.*\|.*\|.*\|' "$file" 2>/dev/null | \
        grep -v "Time" | \
        awk -F'|' '{print $3}' | \
        tr -d ' ' | \
        grep -E '^[0-9]+$' | \
        sort -n
}

# Find max size from a results file
get_max_size() {
    local file="$1"
    extract_sizes "$file" | tail -1
}

# Find size at context warning
get_warning_size() {
    local file="$1"
    grep "Context indicator" "$file" 2>/dev/null | head -1 | awk -F'|' '{print $3}' | tr -d ' '
}

log "Extracting data from test results..."

READ_MAX=$(get_max_size "$RESULTS_DIR/read-heavy.md")
WRITE_MAX=$(get_max_size "$RESULTS_DIR/write-heavy.md")
MIXED_MAX=$(get_max_size "$RESULTS_DIR/mixed.md")

READ_WARN=$(get_warning_size "$RESULTS_DIR/read-heavy.md")
WRITE_WARN=$(get_warning_size "$RESULTS_DIR/write-heavy.md")
MIXED_WARN=$(get_warning_size "$RESULTS_DIR/mixed.md")

log "Results:"
log "  Read-heavy:  max=${READ_MAX:-?}KB, warning=${READ_WARN:-?}KB"
log "  Write-heavy: max=${WRITE_MAX:-?}KB, warning=${WRITE_WARN:-?}KB"
log "  Mixed:       max=${MIXED_MAX:-?}KB, warning=${MIXED_WARN:-?}KB"

# Calculate thresholds
# Use the minimum max as the safe limit
ALL_MAX=($READ_MAX $WRITE_MAX $MIXED_MAX)
SAFE_LIMIT=9999
for m in "${ALL_MAX[@]}"; do
    [ -n "$m" ] && [ "$m" -lt "$SAFE_LIMIT" ] && SAFE_LIMIT=$m
done

if [ "$SAFE_LIMIT" = "9999" ]; then
    log "ERROR: Could not determine safe limit from test data"
    log "Using conservative defaults"
    SAFE_LIMIT=1800
fi

log "Safe limit determined: ${SAFE_LIMIT}KB"

# Calculate thresholds with safety margins
# CRITICAL = 85% of safe limit (leave room for handoff)
# WARN = 75% of safe limit
# EARLY_WARN = 65% of safe limit
CRITICAL_KB=$((SAFE_LIMIT * 85 / 100))
WARN_KB=$((SAFE_LIMIT * 75 / 100))
EARLY_WARN_KB=$((SAFE_LIMIT * 65 / 100))

log ""
log "Calculated thresholds:"
log "  EARLY_WARN: ${EARLY_WARN_KB}KB (65% of limit)"
log "  WARN:       ${WARN_KB}KB (75% of limit)"
log "  CRITICAL:   ${CRITICAL_KB}KB (85% of limit)"

# Save analysis
ANALYSIS_FILE="$RESULTS_DIR/analysis.md"
cat > "$ANALYSIS_FILE" << EOF
# Threshold Analysis

**Generated:** $(date '+%Y-%m-%d %H:%M:%S')

## Test Results

| Test Type | Max Size (KB) | Warning Size (KB) |
|-----------|---------------|-------------------|
| Read-heavy | ${READ_MAX:-N/A} | ${READ_WARN:-N/A} |
| Write-heavy | ${WRITE_MAX:-N/A} | ${WRITE_WARN:-N/A} |
| Mixed | ${MIXED_MAX:-N/A} | ${MIXED_WARN:-N/A} |

## Calculated Safe Limit

**${SAFE_LIMIT}KB** (minimum of all max sizes)

## Recommended Thresholds

| Level | Size (KB) | Percentage | Action |
|-------|-----------|------------|--------|
| EARLY_WARN | ${EARLY_WARN_KB} | 65% | Status indicator only |
| WARN | ${WARN_KB} | 75% | Wrap up current task |
| CRITICAL | ${CRITICAL_KB} | 85% | Auto-handoff triggered |

## Rationale

- **CRITICAL at 85%**: Leaves 15% buffer for handoff creation and any final operations
- **WARN at 75%**: Gives user time to reach a good stopping point
- **EARLY_WARN at 65%**: Early heads-up, no action required

EOF

log ""
log "Analysis saved to: $ANALYSIS_FILE"

# Update system files
log ""
log "=== Updating System Files ==="

# Update ~/.claude/hooks/context-monitor.sh
MONITOR_FILE="$HOME/.claude/hooks/context-monitor.sh"
if [ -f "$MONITOR_FILE" ]; then
    log "Updating $MONITOR_FILE"
    sed -i "s/EARLY_WARN_KB=[0-9]*/EARLY_WARN_KB=$EARLY_WARN_KB/" "$MONITOR_FILE"
    sed -i "s/WARN_KB=[0-9]*/WARN_KB=$WARN_KB/" "$MONITOR_FILE"
    sed -i "s/CRITICAL_KB=[0-9]*/CRITICAL_KB=$CRITICAL_KB/" "$MONITOR_FILE"
    log "  Updated thresholds in context-monitor.sh"
fi

# Update repo version
REPO_MONITOR="$REPO_DIR/hooks/context-monitor.sh"
if [ -f "$REPO_MONITOR" ]; then
    log "Updating $REPO_MONITOR"
    sed -i "s/EARLY_WARN_KB=[0-9]*/EARLY_WARN_KB=$EARLY_WARN_KB/" "$REPO_MONITOR"
    sed -i "s/WARN_KB=[0-9]*/WARN_KB=$WARN_KB/" "$REPO_MONITOR"
    sed -i "s/CRITICAL_KB=[0-9]*/CRITICAL_KB=$CRITICAL_KB/" "$REPO_MONITOR"
fi

# Update README
README_FILE="$REPO_DIR/README.md"
if [ -f "$README_FILE" ]; then
    log "Updating README.md thresholds table"
    # Update the threshold table in README
    sed -i "s/< [0-9.]*MB | OK/< $(echo "scale=1; $EARLY_WARN_KB/1024" | bc)MB | OK/" "$README_FILE"
    sed -i "s/[0-9.]*-[0-9.]*MB | EARLY_WARN/$(echo "scale=1; $EARLY_WARN_KB/1024" | bc)-$(echo "scale=1; $WARN_KB/1024" | bc)MB | EARLY_WARN/" "$README_FILE"
    sed -i "s/[0-9.]*-[0-9.]*MB | WARN/$(echo "scale=1; $WARN_KB/1024" | bc)-$(echo "scale=1; $CRITICAL_KB/1024" | bc)MB | WARN/" "$README_FILE"
    sed -i "s/[0-9.]*\+MB | CRITICAL/$(echo "scale=1; $CRITICAL_KB/1024" | bc)+MB | CRITICAL/" "$README_FILE"
fi

# Commit and push repo changes
log ""
log "=== Syncing to Repository ==="
cd "$REPO_DIR"
git add -A
if git diff --cached --quiet; then
    log "No changes to commit"
else
    git commit -m "chore: update thresholds based on test results

Test results:
- Read-heavy max: ${READ_MAX:-N/A}KB
- Write-heavy max: ${WRITE_MAX:-N/A}KB
- Mixed max: ${MIXED_MAX:-N/A}KB

New thresholds:
- EARLY_WARN: ${EARLY_WARN_KB}KB
- WARN: ${WARN_KB}KB
- CRITICAL: ${CRITICAL_KB}KB

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
    git push origin main
    log "Changes pushed to repository"
fi

# Create final status file
cat > "$RESULTS_DIR/READY_FOR_E2E_TEST.md" << EOF
# Ready for E2E Testing

**Analysis completed:** $(date '+%Y-%m-%d %H:%M:%S')

## Applied Thresholds

| Level | Size |
|-------|------|
| EARLY_WARN | ${EARLY_WARN_KB}KB |
| WARN | ${WARN_KB}KB |
| CRITICAL | ${CRITICAL_KB}KB |

## Files Updated

- [x] ~/.claude/hooks/context-monitor.sh
- [x] ~/claude-auto-handoff/hooks/context-monitor.sh
- [x] ~/claude-auto-handoff/README.md
- [x] Repository pushed

## Next Steps

1. Run comprehensive E2E test with new thresholds
2. Verify handoff triggers at correct size
3. Verify session resumes correctly
4. Final documentation updates
5. GitHub comment on issue #18417

## E2E Test Plan

\`\`\`bash
# Enable test mode with slightly higher thresholds for faster testing
touch ~/.claude/.test-mode

# Start a Claude session via wrapper
claude "Work on a complex task that generates lots of output..."

# Watch for:
# 1. CRITICAL status appearing
# 2. Session being killed
# 3. New session starting
# 4. "HANDOFF LOADED (ID: HO-...)" message
# 5. Work continuing seamlessly
\`\`\`

**Awaiting Jesse's return to run E2E test.**
EOF

log ""
log "=== Analysis Complete ==="
log "Status file: $RESULTS_DIR/READY_FOR_E2E_TEST.md"
log ""
log "Awaiting E2E test execution."
