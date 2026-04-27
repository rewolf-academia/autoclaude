#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Installing autoclaude from $REPO_DIR..."

# Symlink the poller into ~/bin so it stays up-to-date with repo changes
mkdir -p "$HOME/bin"
ln -sf "$REPO_DIR/bin/autoclaude-poller" "$HOME/bin/autoclaude-poller"
chmod +x "$REPO_DIR/bin/autoclaude-poller"
echo "  → ~/bin/autoclaude-poller (symlink)"

# Install systemd user units
mkdir -p "$HOME/.config/systemd/user"
cp "$REPO_DIR/systemd/autoclaude-poller.service" "$HOME/.config/systemd/user/"
cp "$REPO_DIR/systemd/autoclaude-poller.timer"   "$HOME/.config/systemd/user/"
echo "  → ~/.config/systemd/user/autoclaude-poller.{service,timer}"

# Create credentials file from example if it doesn't already exist
if [ ! -f "$HOME/.autoclaude.env" ]; then
  cp "$REPO_DIR/.env.example" "$HOME/.autoclaude.env"
  chmod 600 "$HOME/.autoclaude.env"
  echo "  → ~/.autoclaude.env (created from .env.example — fill in your credentials)"
else
  echo "  → ~/.autoclaude.env already exists, leaving it unchanged"
fi

# Create runtime directories
mkdir -p "$HOME/worktrees" "$HOME/logs"

# Reload systemd so it picks up the new/updated unit files
systemctl --user daemon-reload
echo "  → systemd daemon reloaded"

echo ""
echo "Done. Next steps:"
echo "  1. Fill in ~/.autoclaude.env with your Jira API token and GitHub token"
echo "  2. Test manually: source ~/.autoclaude.env && ~/bin/autoclaude-poller"
echo "  3. Enable the timer: systemctl --user enable --now autoclaude-poller.timer"
echo "  4. Watch logs: tail -f ~/logs/autoclaude-poller.log"
