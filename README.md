# autoclaude

Polls Jira for tickets labeled `claude-automate`, runs Claude Code on each one in an isolated git worktree, pushes the branch, opens a PR, and updates the Jira ticket.

## How it works

1. A systemd timer fires every 5 minutes and runs `bin/autoclaude-poller`
2. The poller acquires a file lock, finds unclaimed tickets, and stamps each one `claude-in-progress`
3. One background worker process is forked per ticket
4. Each worker creates a git worktree, runs Claude Code with full `bypassPermissions`, then pushes the branch and opens a PR against upstream
5. On success the ticket is transitioned to In Review and stamped `claude-in-review`; on failure labels are reset for retry
6. Each poll also checks `claude-in-review` tickets for new human comments on their PRs; if found, a worker is spawned to address them

## Setup

```bash
# 1. Fill in credentials
cp .env.example ~/.autoclaude.env
chmod 600 ~/.autoclaude.env
$EDITOR ~/.autoclaude.env

# 2. Install (symlinks binary, installs systemd units, reloads daemon)
./install.sh
```

## Starting and stopping

```bash
# Enable and start the timer (survives reboots)
systemctl --user enable --now autoclaude-poller.timer

# Stop the timer (in-flight workers keep running until they finish)
systemctl --user stop autoclaude-poller.timer

# Disable the timer so it doesn't start on next login
systemctl --user disable autoclaude-poller.timer

# Trigger a one-shot run immediately (without waiting for the 5-minute tick)
systemctl --user start autoclaude-poller.service
```

## Status and logs

```bash
# Timer and service status
systemctl --user status autoclaude-poller.timer
systemctl --user status autoclaude-poller.service

# Structured poller log (one file per day)
tail -f ~/logs/autoclaude-poller.log

# systemd journal (captures stdout/stderr from the service unit)
journalctl --user -u autoclaude-poller.service -f
```

## Triggering a ticket

Add the `claude-automate` label to any Jira ticket. The poller will pick it up within 5 minutes. While work is in progress the ticket carries the `claude-in-progress` label; once the PR is open it carries `claude-in-review`. If a human leaves review comments on the PR, the poller will pick them up and address them automatically.

## Configuration

All configuration lives in `~/.autoclaude.env`. See `.env.example` for the full list of variables. Required:

| Variable | Description |
|---|---|
| `JIRA_BASE_URL` | e.g. `https://your-org.atlassian.net` |
| `JIRA_EMAIL` | Your Jira login email |
| `JIRA_API_TOKEN` | [Create here](https://id.atlassian.com/manage-profile/security/api-tokens) |
| `GITHUB_TOKEN` | PAT with `repo` + `pull_requests:write` scopes |
| `GITHUB_UPSTREAM_REPO` | e.g. `your-org/your-repo` |
| `GITHUB_FORK_OWNER` | GitHub user/org that owns the fork |

## File layout

```
bin/autoclaude-poller    # Entry point: polling, locking, claiming tickets, spawning workers
lib/ticket_processor.rb  # Worker logic: worktree setup, Claude execution, PR creation, Jira updates
systemd/                 # Service and timer unit files
install.sh               # One-time setup script
```
