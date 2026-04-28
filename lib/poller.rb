# frozen_string_literal: true

# Jira → Claude Code automation poller.
#
# Polls Jira for tickets labeled `claude-automate`, spins up a Claude Code
# instance per ticket in an isolated git worktree, pushes the branch, opens
# a PR via the GitHub API, and updates the Jira ticket.
#
# Also polls tickets labeled `claude-in-review` for new human review comments
# on their PRs and spawns a worker to address them.
#
# Each ticket is handled by an independent background process, so multiple
# tickets can be worked on simultaneously.
#
# Required env vars (set in ~/.autoclaude.env, loaded by the systemd service):
#   JIRA_BASE_URL          e.g. https://academia-edu.atlassian.net
#   JIRA_EMAIL             your Jira login email
#   JIRA_API_TOKEN         Jira API token (id.atlassian.com → Security → API tokens)
#   GITHUB_TOKEN           GitHub PAT with repo + pull_requests:write scopes

require 'logger'
require 'fileutils'
require 'time'
require_relative 'orchestrator'
require_relative 'ticket_processor'

# ── Configuration ─────────────────────────────────────────────────────────────

JIRA_EMAIL           = ENV.fetch('JIRA_EMAIL')
JIRA_API_TOKEN       = ENV.fetch('JIRA_API_TOKEN')
GITHUB_TOKEN         = ENV.fetch('GITHUB_TOKEN')
GITHUB_UPSTREAM_REPO = ENV.fetch('GITHUB_UPSTREAM_REPO', 'academia-edu/academia-app')
LOGS_PATH            = File.expand_path('~/logs')

# ── Logging ───────────────────────────────────────────────────────────────────

FileUtils.mkdir_p(LOGS_PATH)
FileUtils.mkdir_p(WORKTREES_PATH)

LOG = Logger.new(File.join(LOGS_PATH, 'autoclaude.log'), 'daily')
LOG.level = Logger::INFO
LOG.formatter = proc { |sev, dt, _, msg| "#{dt.strftime('%Y-%m-%dT%H:%M:%S')} [#{sev}] #{msg}\n" }

$stdout.sync = true

# ── Entry point ───────────────────────────────────────────────────────────────
#
# Phase 1 (under lock): claim all new tickets AND any in-review tickets that
#   have new human comments since the last push. Both sets are claimed by
#   adding the in-progress label. Claiming must be serial to prevent two
#   poller instances from picking up the same work.
#
# Phase 2 (lock released): fork one independent worker per claimed item.
#   Workers run concurrently and can each take up to an hour or more.
def run_poller
  lock_fd = File.open('/tmp/autoclaude.lock', 'w')
  unless lock_fd.flock(File::LOCK_EX | File::LOCK_NB)
    LOG.info('Another poll is already running — exiting')
    exit 0
  end

  claimed = claimed_reviews = nil

  begin
    jira   = JiraClient.new(JIRA_BASE_URL, JIRA_EMAIL, JIRA_API_TOKEN)
    github = GitHubClient.new(GITHUB_TOKEN, GITHUB_UPSTREAM_REPO)
    claimed, claimed_reviews = poll(jira: jira, github: github)
  rescue => e
    LOG.error("Poll error: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
    exit 1
  ensure
    lock_fd.flock(File::LOCK_UN)
    lock_fd.close
  end

  claimed.each do |issue|
    pid = Process.fork { process_ticket(issue, jira, github) }
    Process.detach(pid)
    LOG.info("#{issue['key']}: worker spawned (pid #{pid})")
  end

  claimed_reviews.each do |work|
    pid = Process.fork { process_review_comments(work[:issue], work[:pr], work[:comments], jira) }
    Process.detach(pid)
    LOG.info("#{work[:issue]['key']}: review worker spawned (pid #{pid})")
  end
end
