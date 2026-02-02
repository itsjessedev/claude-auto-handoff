# Claude Auto-Handoff

**Walk-away automation for Claude Code** - seamless session continuity without context loss.

> **Status:** Under active development. The core system works but edge cases are still being refined.

## The Problem

Claude Code's context window fills up during long tasks. When it hits the limit, auto-compact summarizes the conversation - losing detailed task state, file references, and progress. Users must either:
- Manually checkpoint and restart frequently
- Re-explain everything after compaction
- Accept degraded performance on complex tasks

## The Solution

Auto-handoff **kills and restarts Claude before compaction** with preserved task state:

1. **Monitor** - Hook tracks transcript size after every tool call
2. **Detect** - When CRITICAL threshold hit, auto-trigger handoff
3. **Create** - Handoff created with manifest tracking (unique ID, session link)
4. **Kill** - Background monitor terminates the process
5. **Restart** - Wrapper starts fresh Claude automatically
6. **Load** - Hook loads handoff content inline (zero tool calls needed)

**Result:** Claude works autonomously for hours/days with no user intervention.

## Quick Start

```bash
git clone https://github.com/itsjessedev/claude-auto-handoff
cd claude-auto-handoff
./install.sh
source ~/.bashrc  # or ~/.zshrc
claude
```

## How It Works

```
┌─────────────────────────────────────────────────────────────┐
│                    WRAPPER SCRIPT                           │
│  - Tracks session (writes ID:path to .current-session)      │
│  - Starts background monitor (checks for restart signal)    │
│  - Launches Claude                                          │
│  - On signal: verify session ID → kill → restart            │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    CLAUDE SESSION                           │
│  PostToolUse hook checks ~/.claude/.current-session         │
│  context-monitor.sh creates handoff + restart signal        │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    NEW SESSION                              │
│  SessionStart hook loads handoff via manifest system        │
│  Claude sees: "HANDOFF LOADED (ID: HO-20260202-...)"        │
└─────────────────────────────────────────────────────────────┘
```

## Key Innovation: Manifest-Based Handoffs

Unlike solutions that use PID-based filenames or glob searches, this system uses a **manifest file** as the single source of truth:

```json
{
  "channel": "global",
  "current": {
    "id": "HO-20260202-064530-c74cc080",
    "session_id": "c74cc080-94b9-4841-b82f-a62cfb8efdc0",
    "created_at": "2026-02-02T06:45:30Z",
    "type": "auto",
    "status": "active"
  }
}
```

**Benefits:**
- **No ambiguity** - One active handoff per channel, always
- **Traceable** - Handoff ID links to session UUID
- **Verifiable** - ID in file header must match manifest
- **Atomic** - All writes via temp+rename pattern

## Components

| File | Purpose |
|------|---------|
| `claude-wrapper` | Main entry point, manages sessions and restarts |
| `hooks/context-monitor.sh` | PostToolUse hook, tracks transcript size |
| `hooks/pre-compact-handoff.sh` | Creates handoff via manifest system |
| `hooks/session-start-from-handoff.sh` | SessionStart hook, loads handoff inline |
| `hooks/lib/handoff-manifest.sh` | Shared manifest library |
| `hooks/lib/get-channel.sh` | Shared channel detection utility |

## Prerequisites

**⚠️ CRITICAL: Disable auto-compact before using this system!**

```bash
# Run Claude, then type:
/config
# Navigate to and disable auto-compact
```

Auto-compact must be OFF for handoffs to work. If enabled, Claude compacts before our thresholds trigger.

## Thresholds

Based on observed context limits (~2MB with auto-compact disabled):

| Size | Status | Action |
|------|--------|--------|
| < 1.3MB | OK | Normal operation |
| 1.3-1.5MB | EARLY_WARN | Status file only |
| 1.5-1.7MB | WARN | Wrap up current task |
| 1.7+MB | CRITICAL | Auto-handoff triggered |

Adjust in `hooks/context-monitor.sh` for your system.

## Channel System

Organize handoffs by project using `~/.claude/channel-registry.json`:

```json
{
  "registry": {
    "/home/user/project-a": "project-a",
    "/home/user/project-b": "project-b",
    "/home/user": "global"
  }
}
```

Longest path match wins.

## Handoff File Format

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

## Commands

| Command | Description |
|---------|-------------|
| `claude` | Start fresh (auto-handoff enabled) |
| `claude --handoff` | Load existing handoff |
| `claude-direct` | Bypass wrapper |

## Requirements

- **Node.js 18+**
- **Claude Code CLI** (`npm install -g @anthropic-ai/claude-code`)
- **jq** (for manifest JSON parsing)

## Limitations

- Requires `--dangerously-skip-permissions` (handled by wrapper)
- No handoff if Claude crashes before CRITICAL threshold
- Fresh handoffs (<2hr) auto-load; older ones expire
- Max 10 auto-restarts (prevents infinite loops)
- Auto-compact must be disabled (see Prerequisites)

## For Anthropic Developers

This implementation demonstrates that session continuity is achievable with existing Claude Code infrastructure (hooks + wrapper). Key insights:

### What's Needed for Native Support

1. **Process lifecycle control** - The wrapper's main job is killing/restarting Claude. A native `--auto-handoff` flag could handle this internally.

2. **Pre-compact hook** - Currently we monitor file size as a proxy. A native hook that fires *before* compaction would be more reliable.

3. **Session state API** - Handoff files are user-defined markdown. A structured state API would be cleaner:
   ```javascript
   claude.saveSessionState({ task, progress, files })
   claude.loadSessionState()
   ```

4. **Permission handling** - Walk-away automation requires `--dangerously-skip-permissions`. A more granular approach (auto-approve only handoff operations) would be safer.

### Architecture Decisions

- **Why kill/restart vs survive compact?** Compaction is lossy by design. A fresh session with explicit state is better than a summarized one.

- **Why wrapper vs hook-only?** Hooks can't restart the parent process. The wrapper provides the control plane.

- **Why manifest system?** Multiple handoff files cause confusion. Single source of truth eliminates ambiguity.

- **Why inline content vs file read?** Eliminates a tool call on every resume. Claude sees handoff in first system message.

See [docs/architecture.md](docs/architecture.md) for full technical details.

## Contributing

Issues and PRs welcome. This started as a personal solution and evolved into something others might find useful.

## License

MIT - see [LICENSE](LICENSE)

## Credits

Developed by Jesse Eldridge + Claude (Opus 4.5), February 2026.

Related: [GitHub Issue #18417](https://github.com/anthropics/claude-code/issues/18417)
