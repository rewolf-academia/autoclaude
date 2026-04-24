#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Installing jira-claude-automation from $REPO_DIR..."

# Symlink the poller into ~/bin so it stays up-to-date with repo changes
mkdir -p "$HOME/bin"
ln -sf "$REPO_DIR/bin/jira-claude-poller" "$HOME/bin/jira-claude-poller"
chmod +x "$REPO_DIR/bin/jira-claude-poller"
echo "  → ~/bin/jira-claude-poller (symlink)"

# Install systemd user units
mkdir -p "$HOME/.config/systemd/user"
cp "$REPO_DIR/systemd/jira-claude-poller.service" "$HOME/.config/systemd/user/"
cp "$REPO_DIR/systemd/jira-claude-poller.timer"   "$HOME/.config/systemd/user/"
echo "  → ~/.config/systemd/user/jira-claude-poller.{service,timer}"

# Create credentials file from example if it doesn't already exist
if [ ! -f "$HOME/.jira-claude.env" ]; then
  cp "$REPO_DIR/.env.example" "$HOME/.jira-claude.env"
  chmod 600 "$HOME/.jira-claude.env"
  echo "  → ~/.jira-claude.env (created from .env.example — fill in your credentials)"
else
  echo "  → ~/.jira-claude.env already exists, leaving it unchanged"
fi

# Create runtime directories
mkdir -p "$HOME/worktrees" "$HOME/logs"

# Reload systemd so it picks up the new/updated unit files
systemctl --user daemon-reload
echo "  → systemd daemon reloaded"

echo ""
echo "Done. Next steps:"
echo "  1. Fill in ~/.jira-claude.env with your Jira API token and GitHub token"
echo "  2. Test manually: source ~/.jira-claude.env && ~/bin/jira-claude-poller"
echo "  3. Enable the timer: systemctl --user enable --now jira-claude-poller.timer"
echo "  4. Watch logs: tail -f ~/logs/jira-claude-poller.log"
