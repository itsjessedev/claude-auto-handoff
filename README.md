# Claude Auto-Handoff

**Walk-away automation for Claude Code** - seamless session continuity without context loss.

## The Problem

Claude Code's context window fills up during long tasks. When it hits the limit, auto-compact summarizes the conversation - losing detailed task state, file references, and progress. Users must either:
- Manually checkpoint and restart frequently
- Re-explain everything after compaction
- Accept degraded performance on complex tasks

## The Solution

Auto-handoff **kills and restarts Claude before compaction** with preserved task state:

1. **Monitor** - Hook tracks transcript size after every tool call
2. **Warn** - Claude sees context status (OK → WARN → CRITICAL)
3. **Handoff** - At CRITICAL, Claude saves state to a handoff file
4. **Kill** - Background monitor terminates the process
5. **Restart** - Wrapper starts fresh Claude automatically
6. **Instant Resume** - Hook loads handoff content inline (zero tool calls)

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
│  - Starts background monitor (checks for restart signal)    │
│  - Launches Claude                                          │
│  - On signal: kill → set load flag → restart                │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    CLAUDE SESSION                           │
│  PostToolUse hook writes status to ~/.claude/.context-status│
│  Claude (per CLAUDE.md): creates handoff + restart signal   │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    NEW SESSION                              │
│  SessionStart hook: loads handoff content INLINE            │
│  Claude sees full context immediately - instant resume      │
└─────────────────────────────────────────────────────────────┘
```

## Key Innovation: Instant Handoff Loading

Unlike solutions that require Claude to read files on startup, this system includes handoff content **directly in the session start hook output**. Claude sees the full handoff in its first system message - zero tool calls needed.

```bash
# Hook output (what Claude sees immediately):
=== HANDOFF LOADED ===
Channel: myproject
Handoff ID: myproject-12345
Previous PID: 12345

# Task Handoff
**Current task:** Implementing user authentication
**Progress:** Database schema done, working on JWT middleware
**Next:** Finish middleware, add route protection
...
=== END HANDOFF ===
```

## Components

| File | Purpose |
|------|---------|
| `bin/claude-wrapper` | Main entry point, manages restarts |
| `hooks/context-monitor.sh` | PostToolUse hook, tracks transcript size |
| `hooks/session-start-from-handoff.sh` | SessionStart hook, loads handoff inline |
| `hooks/lib/get-channel.sh` | Shared channel detection utility |

## Thresholds

Based on observed auto-compact trigger at ~1.4MB:

| Size | Status | Action |
|------|--------|--------|
| < 800KB | OK | Normal operation |
| 800KB-1MB | EARLY_WARN | Status file only |
| 1-1.2MB | WARN | Wrap up current task |
| 1.2+MB | CRITICAL | Handoff NOW |

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

## Commands

| Command | Description |
|---------|-------------|
| `claude` | Start fresh (auto-handoff enabled) |
| `claude --handoff` | Load existing handoff |
| `claude-direct` | Bypass wrapper |

## Requirements

- **Node.js 18+**
- **Claude Code CLI** (`npm install -g @anthropic-ai/claude-code`)
- **memory-keeper MCP** (installed automatically)

## Limitations

- Requires `--dangerously-skip-permissions` (handled by wrapper)
- No handoff if Claude crashes before saving state
- 2-hour handoff expiry (prevents stale state)
- Max 10 auto-restarts (prevents infinite loops)

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

- **Why inline content vs file read?** Eliminates a tool call on every resume. Claude sees handoff in first system message.

- **Why atomic mkdir locks?** Multiple Claude instances can run simultaneously. Directory-based locks prevent race conditions.

See [docs/architecture.md](docs/architecture.md) for full technical details.

## Contributing

Issues and PRs welcome. This started as a personal solution and evolved into something others might find useful.

## License

MIT - see [LICENSE](LICENSE)

## Credits

Developed by Jesse Eldridge + Claude (Opus 4.5), February 2026.

Related: [GitHub Issue #18417](https://github.com/anthropics/claude-code/issues/18417)
