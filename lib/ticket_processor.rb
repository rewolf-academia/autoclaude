# frozen_string_literal: true

require 'open3'
require 'base64'
require 'tempfile'

JIRA_BASE_URL        = ENV.fetch('JIRA_BASE_URL')
GITHUB_FORK_OWNER    = ENV.fetch('GITHUB_FORK_OWNER', 'academia-edu')
REVIEWER_GITHUB_USER = ENV.fetch('REVIEWER_GITHUB_USER', '')
REPO_PATH            = ENV.fetch('REPO_PATH', File.expand_path('~/code/academia-app'))
WORKTREES_PATH       = File.expand_path('~/worktrees')
CLAUDE_BIN           = ENV.fetch('CLAUDE_BIN', '/home/claude/.local/bin/claude')
PROJECT_CONTEXT_PATH = ENV.fetch('PROJECT_CONTEXT_PATH', nil)

def project_context
  return '' if PROJECT_CONTEXT_PATH.empty?
  File.read(PROJECT_CONTEXT_PATH).strip
rescue => e
  LOG.error("Could not read project context file at #{PROJECT_CONTEXT_PATH}: #{e.message}")
  ''
end

def adf_to_text(node)
  return '' unless node.is_a?(Hash)
  return node['text'] || '' if node['type'] == 'text'
  return "[image]\n" if node['type'] == 'media'

  suffix = %w[paragraph bulletList orderedList heading].include?(node['type']) ? "\n" : ''
  prefix = node['type'] == 'listItem' ? '- ' : ''
  "#{prefix}#{Array(node['content']).map { |c| adf_to_text(c) }.join}#{suffix}"
end

def adf_extract_external_images(node)
  return [] unless node.is_a?(Hash)
  results = []
  if node['type'] == 'media' && node.dig('attrs', 'type') == 'external'
    url = node.dig('attrs', 'url') || node.dig('attrs', 'id')
    results << url if url
  end
  Array(node['content']).each { |c| results.concat(adf_extract_external_images(c)) }
  results
end

IMAGE_SIZE_LIMIT = 5 * 1024 * 1024 # 5 MB

def download_ticket_images(issue, jira)
  adf = issue.dig('fields', 'description') || {}
  tempfiles = []

  # Jira-hosted image attachments
  Array(issue.dig('fields', 'attachment')).each do |att|
    mime = att['mimeType'].to_s
    next unless mime.start_with?('image/')

    begin
      content, content_type = jira.download_attachment(att['content'])
      next unless content && content.bytesize <= IMAGE_SIZE_LIMIT

      mime_clean = (content_type || mime).split(';').first.strip
      ext = mime_clean.split('/').last
      tmp = Tempfile.new(['autoclaude_img', ".#{ext}"])
      tmp.binmode
      tmp.write(content)
      tmp.flush
      tempfiles << { file: tmp, media_type: mime_clean }
    rescue => e
      LOG.warn("Could not download attachment #{att['filename']}: #{e.message}")
    end
  end

  # External images embedded in the description ADF
  adf_extract_external_images(adf).each do |url|
    begin
      uri = URI(url)
      response = Net::HTTP.get_response(uri)
      if response.is_a?(Net::HTTPRedirection)
        response = Net::HTTP.get_response(URI(response['location']))
      end
      content = response.body
      content_type = response['content-type'].to_s.split(';').first.strip
      next unless content_type.start_with?('image/') && content.bytesize <= IMAGE_SIZE_LIMIT

      ext = content_type.split('/').last
      tmp = Tempfile.new(['autoclaude_img', ".#{ext}"])
      tmp.binmode
      tmp.write(content)
      tmp.flush
      tempfiles << { file: tmp, media_type: content_type }
    rescue => e
      LOG.warn("Could not download external image #{url}: #{e.message}")
    end
  end

  tempfiles
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

def run_logged(cmd, cwd:, tag:, images: [])
  LOG.info("#{tag}: $ #{cmd.join(' ')}#{images.empty? ? '' : " [+#{images.length} image(s)]"}")
  output = +''

  if images.empty?
    Open3.popen2e(*cmd, chdir: cwd) do |_i, io, thr|
      io.each_line do |line|
        output << line
        LOG.debug("#{tag}| #{line.chomp}")
      end
      [output, thr.value.success?]
    end
  else
    # Build a stream-json command by replacing --output-format text with stream-json
    prompt = cmd.last
    stream_cmd = cmd[0..-2].dup
    if (idx = stream_cmd.index('--output-format'))
      stream_cmd[idx + 1] = 'stream-json'
    end
    stream_cmd += ['--verbose', '--input-format', 'stream-json']

    content = [{ type: 'text', text: prompt }]
    images.each do |img|
      content << {
        type: 'image',
        source: {
          type: 'base64',
          media_type: img[:media_type],
          data: Base64.strict_encode64(File.binread(img[:file].path))
        }
      }
    end
    json_msg = JSON.generate({ type: 'user', message: { role: 'user', content: content } })

    result_text = nil
    is_success  = false

    Open3.popen2e(*stream_cmd, chdir: cwd) do |stdin, io, thr|
      stdin.puts(json_msg)
      stdin.close

      io.each_line do |line|
        LOG.debug("#{tag}| #{line.chomp}")
        begin
          event = JSON.parse(line)
          case event['type']
          when 'assistant'
            Array(event.dig('message', 'content')).each do |block|
              output << block['text'] if block['type'] == 'text'
            end
          when 'result'
            result_text = event['result']
            is_success  = !event['is_error'] && event['subtype'] == 'success'
          end
        rescue JSON::ParseError
          # non-JSON diagnostic lines — ignore
        end
      end

      [result_text || output, is_success]
    end
  end
end

def build_prompt(key, title, desc, branch, pr_template, project_context: '')
  <<~PROMPT
    You are working on Jira ticket #{key}: #{title}

    #{project_context.empty? ? '' : "**Project context:**\n#{project_context.strip}"}

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

def build_review_prompt(key, title, branch, pr_url, comments, project_context: nil)
  formatted_comments = comments.map.with_index(1) do |c, i|
    if c['path']
      header = "**Comment #{i} — @#{c.dig('user', 'login')} on `#{c['path']}` line #{c['line'] || c['original_line']}:**"
    else
      header = "**Comment #{i} — @#{c.dig('user', 'login')}:**"
    end
    "#{header}\n#{c['body']}"
  end.join("\n\n---\n\n")

  <<~PROMPT
    You are addressing human review comments on a pull request.

    #{project_context.empty? ? '' : "**Project context:**\n#{project_context.strip}"}

    **Jira ticket:** [#{key}](#{JIRA_BASE_URL}/browse/#{key}): #{title}
    **PR:** #{pr_url}
    **Branch:** #{branch}

    **Human review comments to address (#{comments.length} total):**

    #{formatted_comments}

    **Instructions:**
    1. Read each comment carefully and make the requested code changes
    2. Run linting on any changed files: `RUBOCOP_SERVER=false bundle exec rubocop -a <file>` for Ruby; `pnpm run lint-fix-single <file>` for JS/TS
    3. Commit all changes with a message like "Address review comments for #{key}"
    4. Do NOT push — the orchestrator handles pushing
    5. Do NOT reply to or resolve the review comments — just make the code changes
  PROMPT
end

def process_ticket(issue, jira, github)
  key    = issue['key']
  title  = issue['fields']['summary']
  desc   = adf_to_text(issue.dig('fields', 'description') || {})
  images = []

  if (tid = jira.find_transition_id(key, 'progress'))
    jira.transition(key, tid)
    LOG.info("#{key}: Jira transitioned to In Progress")
  else
    LOG.warn("#{key}: no 'progress' transition found — Jira status unchanged")
  end

  branch   = "autoclaude-#{key.downcase}--#{branch_slug(title)}"
  worktree = File.join(WORKTREES_PATH, key)

  LOG.info("#{key}: starting work on \"#{title}\"")

  if File.exist?(worktree)
    LOG.warn("#{key}: worktree already exists at #{worktree} — skipping to avoid duplicate work")
    return
  end

  images = download_ticket_images(issue, jira)
  LOG.info("#{key}: downloaded #{images.length} image(s) from ticket") unless images.empty?

  system("git -C #{REPO_PATH} fetch upstream --quiet 2>&1")

  unless system("git -C #{REPO_PATH} worktree add #{worktree} -b #{branch} upstream/master 2>&1")
    raise "Failed to create worktree at #{worktree}"
  end

  pr_template = File.read(File.join(REPO_PATH, '.github', 'pull_request_template.md'))
  prompt = build_prompt(key, title, desc, branch, pr_template, project_context: project_context)
  output, claude_ok = run_logged(
    [CLAUDE_BIN, '--print', '--no-session-persistence',
     '--permission-mode', 'bypassPermissions',
     '--output-format', 'text', prompt],
    cwd: worktree,
    tag: key,
    images: images
  )

  raise "Claude exited non-zero for #{key}" unless claude_ok

  pr_description = extract_pr_description(output) ||
    "Automated implementation of [#{key}](#{JIRA_BASE_URL}/browse/#{key}): #{title}\n\n" \
    "🤖 Generated with [Claude Code](https://claude.com/claude-code)"

  _, push_ok = run_logged(['git', 'push', 'origin', branch], cwd: worktree, tag: "#{key}/push")
  raise "git push failed for #{key}" unless push_ok

  head   = "#{GITHUB_ORG}:#{branch}"
  pr_url = github.create_pull_request(title: "[#{key}] #{title}", head: head, body: pr_description)
  raise "PR creation returned no URL for #{key}" unless pr_url

  LOG.info("#{key}: PR opened at #{pr_url}")

  # pr_number = pr_url.split('/').last.to_i
  # TODO: this doesn't work currently since you can't request review from the PR author
  # github.request_review(pr_number, REVIEWER_GITHUB_USER)

  if (tid = jira.find_transition_id(key, 'review'))
    jira.transition(key, tid)
    LOG.info("#{key}: Jira transitioned to In Review")
  else
    LOG.warn("#{key}: no 'review' transition found — Jira status unchanged")
  end

  # reviewer_line = REVIEWER_GITHUB_USER.empty? ? '' : "\nRequested reviewer: @#{REVIEWER_GITHUB_USER}"
  # jira.add_comment(key, "Claude has completed this ticket.\n\nPR: #{pr_url}#{reviewer_line}")
  jira.add_comment(key, "Claude has completed this ticket.\n\nPR: #{pr_url}")

  jira.remove_label(key, IN_PROGRESS_LABEL)
  jira.add_label(key, IN_REVIEW_LABEL)

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
  images.each { |img| img[:file].close! rescue nil }
  if File.exist?(worktree)
    system("git -C #{REPO_PATH} worktree remove #{worktree} --force 2>/dev/null")
    LOG.info("#{key}: worktree cleaned up")
  end
end

def process_review_comments(issue, pr, comments, jira)
  key      = issue['key']
  title    = issue['fields']['summary']
  branch   = pr['head']['ref']
  pr_url   = pr['html_url']
  worktree = File.join(WORKTREES_PATH, "#{key}-review")

  LOG.info("#{key}: addressing #{comments.length} review comment(s) on #{pr_url}")

  if File.exist?(worktree)
    LOG.warn("#{key}: review worktree already exists — skipping to avoid duplicate work")
    return
  end

  # Fetch latest state of the branch, reset local ref, then create worktree
  system("git -C #{REPO_PATH} fetch origin #{branch} --quiet 2>&1")
  system("git -C #{REPO_PATH} branch -D #{branch} 2>/dev/null; true")
  unless system("git -C #{REPO_PATH} worktree add -b #{branch} #{worktree} origin/#{branch} 2>&1")
    raise "Failed to create review worktree for #{key}"
  end

  prompt = build_review_prompt(key, title, branch, pr_url, comments, project_context: project_context)
  _, claude_ok = run_logged(
    [CLAUDE_BIN, '--print', '--no-session-persistence',
     '--permission-mode', 'bypassPermissions',
     '--output-format', 'text', prompt],
    cwd: worktree,
    tag: "#{key}/review"
  )

  raise "Claude exited non-zero addressing review for #{key}" unless claude_ok

  _, push_ok = run_logged(['git', 'push', 'origin', branch], cwd: worktree, tag: "#{key}/review-push")
  raise "git push failed for #{key} review" unless push_ok

  jira.remove_label(key, IN_PROGRESS_LABEL)
  jira.add_comment(key, "Claude has addressed the review comments on #{pr_url}")

  LOG.info("#{key}: review comments addressed")
rescue => e
  LOG.error("#{key}: review FAILED — #{e.message}")
  LOG.error(e.backtrace.first(8).join("\n"))
  begin
    jira.remove_label(key, IN_PROGRESS_LABEL)
    jira.add_comment(key, "Claude encountered an error addressing review comments.\n\nError: #{e.message}")
  rescue => jira_err
    LOG.error("#{key}: could not reset Jira labels — #{jira_err.message}")
  end
ensure
  if File.exist?(worktree)
    system("git -C #{REPO_PATH} worktree remove #{worktree} --force 2>/dev/null")
    LOG.info("#{key}: review worktree cleaned up")
  end
end
