# frozen_string_literal: true

# Helpers and ticket processing logic for individual Jira tickets.
# Constants (JIRA_BASE_URL, REPO_PATH, etc.), LOG, and the API clients
# are defined in the main poller script that requires this file.

require 'open3'

def adf_to_text(node)
  return '' unless node.is_a?(Hash)
  return node['text'] || '' if node['type'] == 'text'

  suffix = %w[paragraph bulletList orderedList heading].include?(node['type']) ? "\n" : ''
  prefix = node['type'] == 'listItem' ? '- ' : ''
  "#{prefix}#{Array(node['content']).map { |c| adf_to_text(c) }.join}#{suffix}"
end

def branch_slug(text)
  text.downcase
      .gsub(/[^a-z0-9\s-]/, '')
      .strip
      .gsub(/\s+/, '-')
      .gsub(/-{2,}/, '-')
      .slice(0, 48)
      .sub(/-+$/, '')
end

def extract_pr_description(output)
  match = output.match(/===PR_DESCRIPTION_START===\n?(.*?)===PR_DESCRIPTION_END===/m)
  match ? match[1].strip : nil
end

def run_logged(cmd, cwd:, tag:)
  LOG.info("#{tag}: $ #{cmd.join(' ')}")
  output = +''
  Open3.popen2e(*cmd, chdir: cwd) do |_i, io, thr|
    io.each_line do |line|
      output << line
      LOG.debug("#{tag}| #{line.chomp}")
    end
    [output, thr.value.success?]
  end
end

def build_prompt(key, title, desc, branch, pr_template)
  <<~PROMPT
    You are working on Jira ticket #{key}: #{title}

    **Ticket description:**
    #{desc.strip.empty? ? '(No description provided — use your best judgement based on the title.)' : desc.strip}

    **Your working context:**
    - You are in a git worktree already checked out on branch `#{branch}` (branched from upstream/master)
    - `origin` = shared fork (academia-edu/yolo-academia-app)
    - `upstream` = canonical repo (academia-edu/academia-app)
    - Rails 8 / React 18 / TypeScript codebase
    - The Jira MCP server is available if you need more context on this ticket

    **Instructions:**
    1. Explore the codebase to understand what needs to change
    2. Implement the changes described in the ticket, following existing patterns
    3. Write or update tests as appropriate (rspec for Ruby, jest for JS/TS)
    4. Run linting: `RUBOCOP_SERVER=false bundle exec rubocop -a <file>` for Ruby; `pnpm run lint-fix-single <file>` for JS/TS
    5. Commit all changes with a clear commit message referencing #{key}
    6. Do NOT push the branch — the orchestrator will handle pushing and PR creation

    **Required: end your response with a PR description between these exact markers.**
    Fill in the template below — replace all placeholder text in italics with real content.
    For the Jira link in the Context section, use: [#{key}](#{JIRA_BASE_URL}/browse/#{key})

    ===PR_DESCRIPTION_START===
    #{pr_template.strip}

    🤖 Generated with [Claude Code](https://claude.com/claude-code)
    ===PR_DESCRIPTION_END===
  PROMPT
end

def process_ticket(issue, jira, github)
  key   = issue['key']
  title = issue['fields']['summary']
  desc  = adf_to_text(issue.dig('fields', 'description') || {})

  branch   = "claude/remy/#{key.downcase}-#{branch_slug(title)}"
  worktree = File.join(WORKTREES_PATH, key)

  LOG.info("#{key}: starting work on \"#{title}\"")

  if File.exist?(worktree)
    LOG.warn("#{key}: worktree already exists at #{worktree} — skipping to avoid duplicate work")
    return
  end

  system("git -C #{REPO_PATH} fetch upstream --quiet 2>&1")

  unless system("git -C #{REPO_PATH} worktree add #{worktree} -b #{branch} upstream/master 2>&1")
    raise "Failed to create worktree at #{worktree}"
  end

  pr_template = File.read(File.join(REPO_PATH, '.github', 'pull_request_template.md'))
  prompt = build_prompt(key, title, desc, branch, pr_template)
  output, claude_ok = run_logged(
    [CLAUDE_BIN, '--print', '--no-session-persistence',
     '--permission-mode', 'bypassPermissions',
     '--output-format', 'text', prompt],
    cwd: worktree,
    tag: key
  )

  raise "Claude exited non-zero for #{key}" unless claude_ok

  pr_description = extract_pr_description(output) ||
    "Automated implementation of [#{key}](#{JIRA_BASE_URL}/browse/#{key}): #{title}\n\n" \
    "🤖 Generated with [Claude Code](https://claude.com/claude-code)"

  _, push_ok = run_logged(['git', 'push', 'origin', branch], cwd: worktree, tag: "#{key}/push")
  raise "git push failed for #{key}" unless push_ok

  head   = "#{GITHUB_FORK_OWNER}:#{branch}"
  pr_url = github.create_pull_request(title: "[#{key}] #{title}", head: head, body: pr_description)
  raise "PR creation returned no URL for #{key}" unless pr_url

  LOG.info("#{key}: PR opened at #{pr_url}")

  pr_number = pr_url.split('/').last.to_i
  github.request_review(pr_number, REVIEWER_GITHUB_USER)

  if (tid = jira.find_transition_id(key, 'review'))
    jira.transition(key, tid)
    LOG.info("#{key}: Jira transitioned to In Review")
  else
    LOG.warn("#{key}: no 'review' transition found — Jira status unchanged")
  end

  reviewer_line = REVIEWER_GITHUB_USER.empty? ? '' : "\nRequested reviewer: @#{REVIEWER_GITHUB_USER}"
  jira.add_comment(key, "Claude has completed this ticket.\n\nPR: #{pr_url}#{reviewer_line}")

  jira.remove_label(key, IN_PROGRESS_LABEL)
  jira.add_label(key, DONE_LABEL)

  LOG.info("#{key}: done")
rescue => e
  LOG.error("#{key}: FAILED — #{e.message}")
  LOG.error(e.backtrace.first(8).join("\n"))
  begin
    jira.remove_label(key, IN_PROGRESS_LABEL)
    jira.add_comment(key, "Claude encountered an error and reset this ticket for retry.\n\nError: #{e.message}")
  rescue => jira_err
    LOG.error("#{key}: could not reset Jira labels — #{jira_err.message}")
  end
ensure
  if File.exist?(worktree)
    system("git -C #{REPO_PATH} worktree remove #{worktree} --force 2>/dev/null")
    LOG.info("#{key}: worktree cleaned up")
  end
end
