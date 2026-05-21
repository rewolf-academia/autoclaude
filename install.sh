#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Installing autoclaude from $REPO_DIR..."

# Symlink the poller into ~/bin so it stays up-to-date with repo changes
mkdir -p "$HOME/bin"
ln -sf "$REPO_DIR/bin/autoclaude" "$HOME/bin/autoclaude"
chmod +x "$REPO_DIR/bin/autoclaude"
echo "  → ~/bin/autoclaude (symlink)"

# Install systemd user units
mkdir -p "$HOME/.config/systemd/user"
cp "$REPO_DIR/systemd/autoclaude.service" "$HOME/.config/systemd/user/"
cp "$REPO_DIR/systemd/autoclaude.timer"   "$HOME/.config/systemd/user/"
echo "  → ~/.config/systemd/user/autoclaude.{service,timer}"

# Create .autoclaude directory if it doesn't already exist
if [ ! -d "$HOME/.autoclaude" ]; then
  mkdir -p "$HOME/.autoclaude"
  echo "  → ~/.autoclaude (created)"
else
  echo "  → ~/.autoclaude already exists, leaving it unchanged"
fi

# Create credentials file from example if it doesn't already exist
if [ ! -f "$HOME/.autoclaude/autoclaude.env" ]; then
  cp "$REPO_DIR/.env.example" "$HOME/.autoclaude/autoclaude.env"
  chmod 600 "$HOME/.autoclaude/autoclaude.env"
  echo "  → ~/.autoclaude/autoclaude.env (created from .env.example — fill in your credentials)"
else
  echo "  → ~/.autoclaude/autoclaude.env already exists, leaving it unchanged"
fi

# Create project context file from example if it doesn't already exist
if [ ! -f "$HOME/.autoclaude/project_context.md" ]; then
  cp "$REPO_DIR/lib/project_context.md" "$HOME/.autoclaude/project_context.md"
  echo "  → ~/.autoclaude/project_context.md (created from project_context.md)"
else
  echo "  → ~/.autoclaude/project_context.md already exists, leaving it unchanged"
fi

# Create runtime directories
mkdir -p "$HOME/worktrees" "$HOME/logs"

# Reload systemd so it picks up the new/updated unit files
systemctl --user daemon-reload
echo "  → systemd daemon reloaded"

echo ""
echo "Done. Next steps:"
echo "  1. Fill in ~/.autoclaude/autoclaude.env with your Jira API token and GitHub token"
echo "  2. Add any additional context that you want to add to the prompt in ~/.autoclaude/project_context.md"
echo "  3. Test manually: source ~/.autoclaude/autoclaude.env && ~/bin/autoclaude"
echo "  4. Enable the timer: systemctl --user enable --now autoclaude.timer"
echo "  5. Watch logs: tail -f ~/logs/autoclaude.log"
