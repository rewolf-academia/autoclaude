# autoclaude

Polls Jira for tickets labeled `claude-automate`, runs Claude Code on each one in an isolated git worktree, pushes the branch, opens a PR, and updates the Jira ticket.

## How it works

1. A systemd timer fires every 2 minutes and runs `bin/jira-claude-poller`
2. The poller acquires a file lock, finds unclaimed tickets, and stamps each one `claude-in-progress`
3. One background worker process is forked per ticket
4. Each worker creates a git worktree, runs Claude Code with full `bypassPermissions`, then pushes the branch and opens a PR against upstream
5. On success the ticket is transitioned to In Review and stamped `claude-done`; on failure labels are reset for retry

## Setup

```bash
# 1. Fill in credentials
cp .env.example ~/.jira-claude.env
chmod 600 ~/.jira-claude.env
$EDITOR ~/.jira-claude.env

# 2. Install (symlinks binary, installs systemd units, reloads daemon)
./install.sh
```

## Starting and stopping

```bash
# Enable and start the timer (survives reboots)
systemctl --user enable --now jira-claude-poller.timer

# Stop the timer (in-flight workers keep running until they finish)
systemctl --user stop jira-claude-poller.timer

# Disable the timer so it doesn't start on next login
systemctl --user disable jira-claude-poller.timer

# Trigger a one-shot run immediately (without waiting for the 2-minute tick)
systemctl --user start jira-claude-poller.service
```

## Status and logs

```bash
# Timer and service status
systemctl --user status jira-claude-poller.timer
systemctl --user status jira-claude-poller.service

# Structured poller log (one file per day)
tail -f ~/logs/jira-claude-poller.log

# systemd journal (captures stdout/stderr from the service unit)
journalctl --user -u jira-claude-poller.service -f
```

## Triggering a ticket

Add the `claude-automate` label to any Jira ticket. The poller will pick it up within 2 minutes. While work is in progress the ticket carries the `claude-in-progress` label; once done it carries `claude-done` and a comment with the PR link.

## Configuration

All configuration lives in `~/.jira-claude.env`. See `.env.example` for the full list of variables. Required:

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
bin/jira-claude-poller   # Entry point: polling, locking, claiming tickets, spawning workers
lib/ticket_processor.rb  # Worker logic: worktree setup, Claude execution, PR creation, Jira updates
systemd/                 # Service and timer unit files
install.sh               # One-time setup script
```
