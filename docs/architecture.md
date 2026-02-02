# Architecture

## System Overview

The auto-handoff system consists of five main components working together:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              WRAPPER SCRIPT                                  │
│                           claude-wrapper                                     │
│                                                                              │
│  ┌─────────────────────┐       ┌─────────────────────────────────────────┐  │
│  │  Session Tracker    │       │  Main Loop                               │  │
│  │  (subshell)         │       │                                          │  │
│  │                     │       │  while true; do                          │  │
│  │  Watches for new    │       │    clean signal files                    │  │
│  │  transcript, writes │───────│    track_session()                       │  │
│  │  ID:path to         │       │    start_monitor()                       │  │
│  │  .current-session   │       │    run Claude                            │  │
│  └─────────────────────┘       │    if killed by monitor → continue       │  │
│                                │    else → break                          │  │
│  ┌─────────────────────┐       └─────────────────────────────────────────┘  │
│  │  Background Monitor │                                                     │
│  │  (subshell)         │                                                     │
│  │                     │                                                     │
│  │  Every 0.25s:       │                                                     │
│  │  - Check for signal │                                                     │
│  │  - Verify session   │                                                     │
│  │  - If match: kill   │                                                     │
│  └─────────────────────┘                                                     │
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
│  │  1. Read ~/.claude/.current-session for transcript path                │  │
│  │  2. Get file size                                                      │  │
│  │  3. Compare against thresholds                                         │  │
│  │  4. Write STATUS:SIZE to ~/.claude/.context-status                     │  │
│  │  5. If CRITICAL: call pre-compact-handoff.sh + create restart signal   │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                                        │                                     │
│                                        ▼                                     │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │  Pre-Compact Hook: pre-compact-handoff.sh                              │  │
│  │                                                                        │  │
│  │  1. Get channel from get-channel.sh                                    │  │
│  │  2. Extract recent context from transcript                             │  │
│  │  3. Call create_handoff() from manifest library                        │  │
│  │  4. Manifest updated with unique handoff ID                            │  │
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
│  │  1. Acquire atomic lock (mkdir-based)                                  │  │
│  │  2. Call load_handoff() from manifest library                          │  │
│  │  3. Manifest verifies: status=active, age<2hr, ID matches file         │  │
│  │  4. JSON-escape content                                                │  │
│  │  5. Include in additionalContext (Claude sees immediately)             │  │
│  │  6. Archive handoff file, update manifest to consumed                  │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
│  Claude sees:                                                                │
│  === HANDOFF LOADED (ID: HO-20260202-064530-c74cc080) ===                    │
│  Channel: global                                                             │
│  Previous Session: c74cc080-94b9-4841-b82f-a62cfb8efdc0                      │
│  Type: auto                                                                  │
│  [full handoff content with metadata header]                                 │
│  === END HANDOFF ===                                                         │
│                                                                              │
│  → Instant resume, zero tool calls needed                                    │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Key Design Decisions

### 1. Manifest-Based Handoff System

**Decision:** Use a JSON manifest file as single source of truth instead of glob-based file search.

**Rationale:** The original system used PID-based filenames (`{channel}-{pid}.md`) and glob searches to find handoffs. This caused problems:
- Multiple handoff files could exist for the same channel
- Unclear which one to load
- Race conditions between creation and consumption
- No way to track handoff state (active, consumed, expired)

The manifest system provides:
- Single active handoff per channel, always
- Unique ID linking handoff to source session
- Status tracking (active → consumed/expired)
- Verification (ID in file must match manifest)
- Audit trail (consumed_by_pid, consumed_at)

### 2. Session Tracking via .current-session

**Decision:** Wrapper writes session ID:transcript_path to a file, hooks read from it.

**Rationale:** The original system used `find` to locate the active transcript. This was:
- Slow (especially with many sessions)
- Could miss the active session
- Couldn't distinguish between parallel sessions

Direct file lookup is:
- Instant (~100x faster)
- Never misses
- Tied to specific wrapper instance

### 3. Session ID Verification Before Kill

**Decision:** Monitor verifies session ID in restart signal matches tracked session.

**Rationale:** Without verification, a stale restart signal from a previous session could kill the wrong Claude instance. The new flow:
1. context-monitor writes `SESSION_ID:WORKING_DIR` to restart signal
2. Monitor reads signal, compares SESSION_ID to tracked session
3. Only kills if IDs match
4. Mismatches are logged and ignored

### 4. Kill/Restart vs Survive Compaction

**Decision:** Kill the process and restart fresh.

**Rationale:** Auto-compaction is lossy by design - it summarizes the conversation, losing detail. A fresh session with explicit, user-defined state is better than a summarized one where you don't control what's kept.

### 5. Wrapper Script vs Hook-Only

**Decision:** Use a wrapper script around Claude.

**Rationale:** Hooks cannot control the parent process lifecycle. They can save state, but they can't kill and restart Claude. The wrapper provides the control plane:
- Spawns session tracker subprocess
- Spawns background monitor subprocess
- Detects when monitor kills Claude (vs user Ctrl+C)
- Restarts with continuation prompt
- Cleans up on exit

### 6. Inline Content vs File Read

**Decision:** Include handoff content directly in hook's `additionalContext` output.

**Rationale:** Earlier versions told Claude to "read the handoff file" on startup. This required a tool call, which took time and could fail. By including content inline, Claude sees the handoff in its first system message - no searching, no reading, instant context.

### 7. Atomic Directory Locks

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

### 8. Channel System

**Decision:** Organize handoffs by "channel" (project) rather than globally.

**Rationale:**
- Prevents cross-project context contamination
- Allows parallel sessions in different projects
- Integrates with memory-keeper MCP's channel concept
- Longest-path-match allows nested project hierarchies

### 9. Handoff ID Format

**Decision:** Use `HO-{YYYYMMDD}-{HHMMSS}-{session_prefix}` format.

**Rationale:**
- `HO-` prefix makes handoffs identifiable
- Timestamp ensures uniqueness
- Session prefix (first 8 chars of UUID) links to source session
- Human-readable in logs and messages

## File Formats

### Manifest File

Location: `~/.claude/handoff/{channel}.manifest.json`

```json
{
  "channel": "global",
  "current": {
    "id": "HO-20260202-064530-c74cc080",
    "session_id": "c74cc080-94b9-4841-b82f-a62cfb8efdc0",
    "created_at": "2026-02-02T06:45:30Z",
    "created_by_pid": 12345,
    "working_dir": "/home/jesse",
    "type": "auto",
    "status": "active"
  }
}
```

Status values:
- `active` - Ready to be loaded
- `consumed` - Loaded by a session
- `expired` - Older than 2 hours
- `cleared` - Manually cleared

### Handoff File

Location: `~/.claude/handoff/{channel}-CURRENT.md`

```markdown
<!-- HANDOFF-ID: HO-20260202-064530-c74cc080 -->
<!-- SESSION: c74cc080-94b9-4841-b82f-a62cfb8efdc0 -->
<!-- CHANNEL: global -->
<!-- CREATED: 2026-02-02T06:45:30Z -->
<!-- TYPE: auto -->
<!-- WORKING-DIR: /home/jesse -->

# Auto-Handoff (Pre-Compaction)

**Timestamp:** 2026-02-02 06:45
**Project:** /home/jesse
**Channel:** global
**Session:** c74cc080-94b9-4841-b82f-a62cfb8efdc0

## Recent Activity

```
user: Continue with the implementation...
assistant: Working on the authentication module...
```

## Instructions for Claude

1. Call `context_get({ channel: 'global', priorities: ['high'] })`
2. Announce: "Restored from auto-handoff. Channel: global"
3. Continue where we left off
```

### Session Tracking File

Location: `~/.claude/.current-session`

```
c74cc080-94b9-4841-b82f-a62cfb8efdc0:/home/jesse/.claude/projects/-home-jesse/c74cc080-94b9-4841-b82f-a62cfb8efdc0.jsonl
```

Format: `{session_uuid}:{transcript_path}`

### Context Status File

Location: `~/.claude/.context-status`

```
CRITICAL:1.7MB
```

Format: `STATUS:SIZE` where STATUS is one of: OK, EARLY_WARN, WARN, CRITICAL

### Restart Signal File

Location: `~/.claude/.restart-session`

```
c74cc080-94b9-4841-b82f-a62cfb8efdc0:/home/jesse
```

Format: `{session_uuid}:{working_directory}`

### Lock Directory

```
~/.claude/handoff/{channel}.lock.d/
└── pid    # Contains: {pid}:{timestamp}
```

## Thresholds

```bash
# Default thresholds (adjust for your system)
EARLY_WARN_KB=1300  # ~1.3MB - status file only
WARN_KB=1500        # ~1.5MB - wrap up current task
CRITICAL_KB=1700    # ~1.7MB - auto-handoff triggered
```

Based on observed context limit at ~2MB with auto-compact disabled. Leave margin for handoff creation.

## Error Handling

### Race Conditions

- **Lock acquisition:** Atomic mkdir with stale lock cleanup
- **File disappears mid-read:** Graceful fallback to fresh start
- **Manifest/file ID mismatch:** Error logged, handoff rejected
- **Session ID mismatch:** Restart signal ignored, logged

### Fallbacks

- **Session file missing:** Falls back to `find` for transcript
- **Python not available:** Fallback to sed-based JSON escaping
- **jq not available:** Basic manifest operations may fail (jq required)
- **Hooks fail silently:** Claude continues, just without monitoring

### Safety Limits

- **Max 10 restarts:** Prevents infinite loops
- **2-hour handoff expiry:** Prevents stale state
- **Exit code 130 handling:** User Ctrl+C never triggers restart

## Shared Library

`hooks/lib/handoff-manifest.sh` provides:

| Function | Purpose |
|----------|---------|
| `get_current_session_id()` | Read session ID from .current-session |
| `get_current_transcript_path()` | Read transcript path from .current-session |
| `generate_handoff_id()` | Create unique HO-{timestamp}-{session} ID |
| `read_manifest()` | Read channel's manifest JSON |
| `write_manifest()` | Atomic write to manifest |
| `create_handoff()` | Create handoff file + update manifest |
| `load_handoff()` | Load and consume handoff |
| `get_active_handoff_file()` | Get path to active handoff |
| `get_active_handoff_id()` | Get ID of active handoff |
| `has_active_handoff()` | Check if active handoff exists |
| `clear_handoff()` | Clear without consuming |
| `extract_recent_context()` | Extract last N messages from transcript |
| `write_session_file()` | Write .current-session (for wrapper) |
| `clear_session_file()` | Remove .current-session |
