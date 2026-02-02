# Architecture

## System Overview

The auto-handoff system consists of four main components working together:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              WRAPPER SCRIPT                                  │
│                         bin/claude-wrapper                                   │
│                                                                              │
│  ┌─────────────────────┐       ┌─────────────────────────────────────────┐  │
│  │  Background Monitor │       │  Main Loop                               │  │
│  │  (subshell)         │       │                                          │  │
│  │                     │       │  while true; do                          │  │
│  │  Every 0.5s:        │       │    clean signal files                    │  │
│  │  - Check for        │       │    set .load-handoff flag if needed      │  │
│  │    restart signal   │───────│    start_monitor()                       │  │
│  │  - If found: kill   │       │    run Claude                            │  │
│  │    Claude process   │       │    if killed by monitor → continue       │  │
│  │                     │       │    else → break                          │  │
│  └─────────────────────┘       └─────────────────────────────────────────┘  │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
                                        │
                                        ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                              CLAUDE SESSION                                  │
│                                                                              │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │  PostToolUse Hook: context-monitor.sh                                  │  │
│  │                                                                        │  │
│  │  After EVERY tool call:                                                │  │
│  │  1. Find current transcript: ~/.claude/projects/*/*.jsonl              │  │
│  │  2. Get file size                                                      │  │
│  │  3. Compare against thresholds                                         │  │
│  │  4. Write STATUS:SIZE to ~/.claude/.context-status                     │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                                        │                                     │
│                                        ▼                                     │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │  Claude's Behavior (per CLAUDE.md instructions)                        │  │
│  │                                                                        │  │
│  │  When status shows CRITICAL:                                           │  │
│  │  1. Save state to handoff file: ~/.claude/handoff/{channel}-{pid}.md   │  │
│  │  2. Create restart signal: ~/.claude/.restart-session                  │  │
│  │  3. Make one more tool call (triggers monitor detection)               │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
                                        │
                                        ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                              NEW SESSION                                     │
│                                                                              │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │  SessionStart Hook: session-start-from-handoff.sh                      │  │
│  │                                                                        │  │
│  │  1. Check for .load-handoff flag (set by wrapper)                      │  │
│  │  2. Acquire atomic lock (mkdir-based)                                  │  │
│  │  3. Find valid handoff file (< 2 hours, dead PID)                      │  │
│  │  4. JSON-escape content                                                │  │
│  │  5. Include in additionalContext (Claude sees immediately)             │  │
│  │  6. Delete handoff file                                                │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
│  Claude sees:                                                                │
│  === HANDOFF LOADED ===                                                      │
│  Channel: myproject                                                          │
│  Handoff ID: myproject-12345                                                 │
│  Previous PID: 12345                                                         │
│  [full handoff content]                                                      │
│  === END HANDOFF ===                                                         │
│                                                                              │
│  → Instant resume, zero tool calls needed                                    │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Key Design Decisions

### 1. Kill/Restart vs Survive Compaction

**Decision:** Kill the process and restart fresh.

**Rationale:** Auto-compaction is lossy by design - it summarizes the conversation, losing detail. A fresh session with explicit, user-defined state is better than a summarized one where you don't control what's kept.

### 2. Wrapper Script vs Hook-Only

**Decision:** Use a wrapper script around Claude.

**Rationale:** Hooks cannot control the parent process lifecycle. They can save state, but they can't kill and restart Claude. The wrapper provides the control plane:
- Spawns a background monitor subprocess
- Detects when monitor kills Claude (vs user Ctrl+C)
- Restarts with continuation prompt
- Manages the load-handoff flag

### 3. Inline Content vs File Read

**Decision:** Include handoff content directly in hook's `additionalContext` output.

**Rationale:** Earlier versions told Claude to "read the handoff file" on startup. This required a tool call, which took time and could fail. By including content inline, Claude sees the handoff in its first system message - no searching, no reading, instant context.

### 4. Atomic Directory Locks

**Decision:** Use `mkdir` for lock acquisition instead of file-based locks.

**Rationale:** Multiple Claude sessions can run simultaneously in the same project. File-based locks have race conditions:
```
Session A: check lock → doesn't exist
Session B: check lock → doesn't exist
Session A: create lock
Session B: create lock (overwrites A!)
```

`mkdir` is atomic on POSIX systems - it either succeeds (you got the lock) or fails (someone else has it):
```bash
if mkdir "$LOCK_DIR" 2>/dev/null; then
    # We have the lock
fi
```

### 5. Channel System

**Decision:** Organize handoffs by "channel" (project) rather than globally.

**Rationale:**
- Prevents cross-project context contamination
- Allows parallel sessions in different projects
- Integrates with memory-keeper MCP's channel concept
- Longest-path-match allows nested project hierarchies

### 6. PID in Handoff Filenames

**Decision:** Include the creating session's PID in handoff filenames: `{channel}-{pid}.md`

**Rationale:**
- Prevents one session from loading another active session's handoff
- Hook checks if PID is alive before loading
- Dead PID = safe to load; alive PID = another session owns it

### 7. 2-Hour Expiry

**Decision:** Ignore handoffs older than 2 hours.

**Rationale:** Stale handoffs cause confusion. If you come back to a project after a day, you probably don't want to continue mid-task from yesterday. Fresh start is cleaner.

## File Formats

### Handoff File

```markdown
# Session Handoff

**Timestamp:** 2026-02-02 03:30
**Channel:** myproject
**Task:** Implementing authentication

## Current Progress
- [x] Database schema
- [x] User model
- [ ] JWT middleware

## Next Steps
1. Finish JWT middleware
2. Add route protection

## Key Files
- src/models/user.ts
- src/middleware/auth.ts
```

### Context Status File

```
CRITICAL:1.2MB
```

Format: `STATUS:SIZE` where STATUS is one of: OK, EARLY_WARN, WARN, CRITICAL

### Restart Signal File

Contains the working directory path:
```
/home/user/myproject
```

### Lock Directory

```
~/.claude/handoff/{channel}.lock.d/
└── pid    # Contains: {pid}:{timestamp}
```

## Thresholds

```bash
# Default thresholds (adjust for your system)
EARLY_WARN_KB=800   # ~800KB - status file only
WARN_KB=1024        # ~1MB - Claude should wrap up
CRITICAL_KB=1200    # ~1.2MB - handoff NOW
```

These are based on observed auto-compact trigger at ~1.4MB. Leave margin for Claude to complete the handoff process.

## Error Handling

### Race Conditions

- **Lock acquisition:** Atomic mkdir with retry
- **File disappears mid-read:** Graceful fallback to fresh start
- **Multiple handoffs for same channel:** Select newest by mtime

### Fallbacks

- **Python not available:** Fallback to sed-based JSON escaping
- **jq not available:** Manual settings.json merge required
- **Hooks fail silently:** Claude continues, just without monitoring

### Safety Limits

- **Max 10 restarts:** Prevents infinite loops
- **2-hour handoff expiry:** Prevents stale state
- **Exit code 130 handling:** User Ctrl+C never triggers restart
