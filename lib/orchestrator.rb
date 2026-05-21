# frozen_string_literal: true

require_relative 'jira_client'
require_relative 'github_client'

# Polls Jira for actionable tickets and returns two arrays:
#   claimed         — new tickets to implement
#   claimed_reviews — in-review tickets with new human comments to address
#
# Relies on constants LOG, TRIGGER_LABEL, IN_PROGRESS_LABEL, IN_REVIEW_LABEL
# being defined in the caller's scope.
def poll(jira:, github:)
  claimed         = []
  claimed_reviews = []

  tickets = jira.find_new_tickets
  if tickets.empty?
    LOG.info('Poll: no new tickets')
  else
    LOG.info("Poll: found #{tickets.length} new ticket(s) — #{tickets.map { |t| t['key'] }.join(', ')}")
    tickets.each do |issue|
      key = issue['key']
      jira.add_label(key, IN_PROGRESS_LABEL)
      claimed << issue
      LOG.info("#{key}: claimed")
    rescue => e
      LOG.error("#{key}: failed to claim — #{e.message}")
    end
  end

  review_tickets = jira.find_in_review_tickets
  if review_tickets.empty?
    LOG.info('Poll: no in-review tickets to check')
  else
    LOG.info("Poll: checking #{review_tickets.length} in-review ticket(s) for new human comments")
    review_tickets.each do |issue|
      key = issue['key']

      pr = github.find_pr_for_ticket(key)
      unless pr
        LOG.info("#{key}: no open PR found — skipping")
        next
      end

      commits = github.pr_commits(pr['number'])
      if commits.empty?
        LOG.warn("#{key}: PR #{pr['number']} has no commits — skipping")
        next
      end

      last_push_at = Time.parse(commits.last['commit']['committer']['date'])

      all_comments = github.pr_review_comments(pr['number']) +
                     github.pr_issue_comments(pr['number']) +
                     github.pr_line_comments(pr['number'])

      human_comments = all_comments
        .reject { |c| c.dig('user', 'type') == 'Bot' }
        .reject { |c| c.dig('user', 'login').to_s.end_with?('[bot]') }
        .reject { |c| c.dig('state') == 'PENDING' }
        .select do |c|
          comment_at = c['submitted_at'] || c['updated_at']
          Time.parse(comment_at) > last_push_at
        end

      if human_comments.empty?
        LOG.info("#{key}: no new human comments since last push")
        next
      end

      LOG.info("#{key}: #{human_comments.length} new human comment(s) found — claiming")
      jira.add_label(key, IN_PROGRESS_LABEL)
      claimed_reviews << { issue: issue, pr: pr, comments: human_comments }
    rescue => e
      LOG.error("#{key}: failed to check review comments — #{e.message}")
    end
  end

  [claimed, claimed_reviews]
end
