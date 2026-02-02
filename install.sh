#!/bin/bash
# Auto-Handoff System Installer
# https://github.com/itsjessedev/claude-auto-handoff
#
# Usage: ./install.sh [--update]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPDATE_MODE=false

[[ "$1" == "--update" ]] && UPDATE_MODE=true

echo "========================================"
echo "  Claude Auto-Handoff System Installer"
echo "========================================"
echo ""

# Check prerequisites
echo "Checking prerequisites..."

if ! command -v node &>/dev/null; then
    echo "ERROR: Node.js is required but not installed."
    echo "Install via: curl -fsSL https://fnm.vercel.app/install | bash && fnm install 20"
    exit 1
fi

NODE_VERSION=$(node -v | cut -d'v' -f2 | cut -d'.' -f1)
if [ "$NODE_VERSION" -lt 18 ]; then
    echo "ERROR: Node.js 18+ required, found v$NODE_VERSION"
    exit 1
fi

if ! command -v claude &>/dev/null; then
    echo "ERROR: Claude Code is required but not installed."
    echo "Install via: npm install -g @anthropic-ai/claude-code"
    exit 1
fi

echo "  Node.js: v$(node -v | cut -d'v' -f2) ✓"
echo "  Claude Code: $(which claude) ✓"
echo ""

# Create directories
echo "Creating directories..."
mkdir -p ~/.claude/hooks/lib
mkdir -p ~/.claude/handoff
mkdir -p ~/.claude/archives
echo "  ~/.claude/hooks/ ✓"
echo "  ~/.claude/handoff/ ✓"
echo "  ~/.claude/archives/ ✓"

# Determine bin location
if [ -d "$HOME/infrastructure/bin" ]; then
    BIN_DIR="$HOME/infrastructure/bin"
else
    BIN_DIR="$HOME/.local/bin"
    mkdir -p "$BIN_DIR"
fi
echo "  $BIN_DIR/ ✓"
echo ""

# Copy hooks
echo "Installing hooks..."
cp "$SCRIPT_DIR/hooks/context-monitor.sh" ~/.claude/hooks/
cp "$SCRIPT_DIR/hooks/session-start-from-handoff.sh" ~/.claude/hooks/
cp "$SCRIPT_DIR/hooks/lib/get-channel.sh" ~/.claude/hooks/lib/
chmod +x ~/.claude/hooks/*.sh ~/.claude/hooks/lib/*.sh
echo "  context-monitor.sh ✓"
echo "  session-start-from-handoff.sh ✓"
echo "  lib/get-channel.sh ✓"
echo ""

# Copy wrapper
echo "Installing wrapper..."
cp "$SCRIPT_DIR/bin/claude-wrapper" "$BIN_DIR/"
chmod +x "$BIN_DIR/claude-wrapper"
echo "  $BIN_DIR/claude-wrapper ✓"
echo ""

# Create channel registry if not exists
if [ ! -f ~/.claude/channel-registry.json ]; then
    echo "Creating channel registry..."
    sed "s|/home/USER|$HOME|g" "$SCRIPT_DIR/templates/channel-registry.json" > ~/.claude/channel-registry.json
    echo "  ~/.claude/channel-registry.json ✓"
    echo ""
fi

# Merge hooks into settings.json
echo "Configuring Claude Code hooks..."
SETTINGS_FILE="$HOME/.claude/settings.json"

if [ -f "$SETTINGS_FILE" ]; then
    # Check if hooks already configured
    if grep -q "session-start-from-handoff" "$SETTINGS_FILE" 2>/dev/null; then
        echo "  Hooks already configured ✓"
    else
        # Backup existing settings
        cp "$SETTINGS_FILE" "$SETTINGS_FILE.bak-$(date +%Y%m%d-%H%M%S)"
        echo "  Backed up existing settings"

        # Try to merge with jq if available
        if command -v jq &>/dev/null; then
            HOOKS_JSON=$(cat "$SCRIPT_DIR/templates/settings-hooks.json")
            jq --argjson hooks "$HOOKS_JSON" '. * $hooks' "$SETTINGS_FILE" > "$SETTINGS_FILE.tmp" && mv "$SETTINGS_FILE.tmp" "$SETTINGS_FILE"
            echo "  Merged hooks into settings.json ✓"
        else
            echo "  WARNING: jq not installed. Please manually merge templates/settings-hooks.json into ~/.claude/settings.json"
        fi
    fi
else
    # Create new settings file
    sed "s|\$HOME|$HOME|g" "$SCRIPT_DIR/templates/settings-hooks.json" > "$SETTINGS_FILE"
    echo "  Created ~/.claude/settings.json ✓"
fi
echo ""

# Set up shell alias
echo "Setting up shell alias..."
SHELL_RC="$HOME/.bashrc"
[[ "$SHELL" == *zsh* ]] && SHELL_RC="$HOME/.zshrc"

if grep -q "alias claude=" "$SHELL_RC" 2>/dev/null; then
    # Update existing alias
    sed -i "s|alias claude=.*|alias claude='$BIN_DIR/claude-wrapper'|" "$SHELL_RC"
    echo "  Updated alias in $SHELL_RC ✓"
else
    echo "" >> "$SHELL_RC"
    echo "# Claude Auto-Handoff" >> "$SHELL_RC"
    echo "alias claude='$BIN_DIR/claude-wrapper'" >> "$SHELL_RC"
    echo "alias claude-direct='$(which claude) --dangerously-skip-permissions'" >> "$SHELL_RC"
    echo "  Added alias to $SHELL_RC ✓"
fi
echo ""

# Install memory-keeper MCP (optional but recommended)
echo "Installing memory-keeper MCP..."
if claude mcp list 2>/dev/null | grep -q "memory-keeper"; then
    echo "  memory-keeper already installed ✓"
else
    claude mcp add memory-keeper -- npx mcp-memory-keeper 2>/dev/null && echo "  memory-keeper installed ✓" || echo "  WARNING: Failed to install memory-keeper (optional)"
fi
echo ""

# Done
echo "========================================"
echo "  Installation Complete!"
echo "========================================"
echo ""
echo "Next steps:"
echo "  1. Run: source $SHELL_RC"
echo "  2. Start Claude: claude"
echo ""
echo "Commands:"
echo "  claude          - Start with auto-handoff enabled"
echo "  claude --handoff - Load existing handoff if available"
echo "  claude-direct   - Bypass wrapper (raw Claude)"
echo ""
echo "To add project channels, edit ~/.claude/channel-registry.json"
echo ""
