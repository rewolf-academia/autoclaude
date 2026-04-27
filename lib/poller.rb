# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'
require 'base64'

TRIGGER_LABEL     = ENV.fetch('TRIGGER_LABEL', 'claude-automate')
IN_PROGRESS_LABEL = 'claude-in-progress'
IN_REVIEW_LABEL   = 'claude-in-review'

class JiraClient
  def initialize(base_url, email, api_token)
    @base_url = base_url.chomp('/')
    @auth = Base64.strict_encode64("#{email}:#{api_token}")
  end

  def find_new_tickets
    jql = %(labels = "#{TRIGGER_LABEL}" AND labels != "#{IN_PROGRESS_LABEL}" AND labels != "#{IN_REVIEW_LABEL}" AND assignee = currentUser() ORDER BY created ASC)
    response = get('/rest/api/3/search', jql: jql, fields: 'summary,description,assignee,labels', maxResults: 10)
    JSON.parse(response.body).fetch('issues', [])
  end

  def find_in_review_tickets
    jql = %(labels = "#{IN_REVIEW_LABEL}" AND labels != "#{IN_PROGRESS_LABEL}" AND assignee = currentUser() ORDER BY created ASC)
    response = get('/rest/api/3/search', jql: jql, fields: 'summary,description,assignee,labels', maxResults: 20)
    JSON.parse(response.body).fetch('issues', [])
  end

  def add_label(key, label)
    put("/rest/api/3/issue/#{key}", update: { labels: [{ add: label }] })
  end

  def remove_label(key, label)
    put("/rest/api/3/issue/#{key}", update: { labels: [{ remove: label }] })
  end

  def find_transition_id(key, name_fragment)
    response = get("/rest/api/3/issue/#{key}/transitions")
    transitions = JSON.parse(response.body).fetch('transitions', [])
    match = transitions.find { |t| t['name'].downcase.include?(name_fragment.downcase) }
    match&.fetch('id')
  end

  def transition(key, transition_id)
    post("/rest/api/3/issue/#{key}/transitions", transition: { id: transition_id })
  end

  def add_comment(key, text)
    post("/rest/api/3/issue/#{key}/comment", body: adf_doc(text))
  end

  private

  def adf_doc(text)
    {
      type: 'doc', version: 1,
      content: [{ type: 'paragraph', content: [{ type: 'text', text: text }] }]
    }
  end

  def get(path, params = {})
    request(Net::HTTP::Get, path, params: params)
  end

  def put(path, body)
    request(Net::HTTP::Put, path, body: body)
  end

  def post(path, body)
    request(Net::HTTP::Post, path, body: body)
  end

  def request(klass, path, params: {}, body: nil)
    uri = URI("#{@base_url}#{path}")
    uri.query = URI.encode_www_form(params) unless params.empty?

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == 'https'
    http.open_timeout = 15
    http.read_timeout = 30

    req = klass.new(uri)
    req['Authorization'] = "Basic #{@auth}"
    req['Content-Type']  = 'application/json'
    req['Accept']        = 'application/json'
    req.body = body.to_json if body

    http.request(req)
  end
end

class GitHubClient
  def initialize(token, upstream_repo)
    @token         = token
    @upstream_repo = upstream_repo
  end

  def create_pull_request(title:, head:, body:)
    response = post("/repos/#{@upstream_repo}/pulls", title: title, head: head, base: 'master', body: body)
    data = JSON.parse(response.body)
    raise "GitHub API error: #{data['message']}" if data['message']
    data['html_url']
  end

  def request_review(pr_number, reviewers)
    reviewers = Array(reviewers).reject(&:empty?)
    return if reviewers.empty?
    post("/repos/#{@upstream_repo}/pulls/#{pr_number}/requested_reviewers", reviewers: reviewers)
  end

  def find_pr_for_ticket(key)
    response = get("/repos/#{@upstream_repo}/pulls", state: 'open', per_page: 100)
    prs = JSON.parse(response.body)
    prs.find { |pr| pr['title'].include?("[#{key}]") }
  end

  def pr_commits(pr_number)
    response = get("/repos/#{@upstream_repo}/pulls/#{pr_number}/commits", per_page: 100)
    JSON.parse(response.body)
  end

  def pr_review_comments(pr_number)
    response = get("/repos/#{@upstream_repo}/pulls/#{pr_number}/comments", per_page: 100)
    JSON.parse(response.body)
  end

  def pr_issue_comments(pr_number)
    response = get("/repos/#{@upstream_repo}/issues/#{pr_number}/comments", per_page: 100)
    JSON.parse(response.body)
  end

  private

  def get(path, params = {})
    uri = URI("https://api.github.com#{path}")
    uri.query = URI.encode_www_form(params) unless params.empty?

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 15
    http.read_timeout = 30

    req = Net::HTTP::Get.new(uri)
    req['Authorization']        = "Bearer #{@token}"
    req['Accept']               = 'application/vnd.github+json'
    req['X-GitHub-Api-Version'] = '2022-11-28'

    http.request(req)
  end

  def post(path, body)
    uri  = URI("https://api.github.com#{path}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 15
    http.read_timeout = 30

    req = Net::HTTP::Post.new(uri)
    req['Authorization']        = "Bearer #{@token}"
    req['Accept']               = 'application/vnd.github+json'
    req['Content-Type']         = 'application/json'
    req['X-GitHub-Api-Version'] = '2022-11-28'
    req.body = body.to_json

    http.request(req)
  end
end

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
                     github.pr_issue_comments(pr['number'])

      human_comments = all_comments
        .reject { |c| c.dig('user', 'type') == 'Bot' }
        .reject { |c| c.dig('user', 'login').to_s.end_with?('[bot]') }
        .select { |c| Time.parse(c['created_at']) > last_push_at }

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
