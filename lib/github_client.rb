# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'

class GitHubClient
  def initialize(token, upstream_repo, fork_repo)
    @token         = token
    @upstream_repo = upstream_repo
    @fork_repo     = fork_repo
  end

  def create_pull_request(title:, head:, body:)
    response = post(
      "/repos/#{@upstream_repo}/pulls",
      title: title,
      head: head,
      head_repo: @fork_repo,
      base: 'master',
      body: body
    )
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

  def pr_line_comments(pr_number)
    response = get("/repos/#{@upstream_repo}/pulls/#{pr_number}/comments", per_page: 100)
    JSON.parse(response.body)
  end

  def pr_issue_comments(pr_number)
    response = get("/repos/#{@upstream_repo}/issues/#{pr_number}/comments", per_page: 100)
    JSON.parse(response.body)
  end

  def pr_review_comments(pr_number)
    response = get("/repos/#{@upstream_repo}/pulls/#{pr_number}/reviews", per_page: 100)
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
    req['X-GitHub-Api-Version'] = '2026-03-10'

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
    req['X-GitHub-Api-Version'] = '2026-03-10'
    req.body = body.to_json

    http.request(req)
  end
end
