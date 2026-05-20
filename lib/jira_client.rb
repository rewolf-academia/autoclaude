# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'

TRIGGER_LABEL     = ENV.fetch('TRIGGER_LABEL', 'claude-automate')
IN_PROGRESS_LABEL = 'claude-in-progress'
IN_REVIEW_LABEL   = 'claude-in-review'

class JiraClient
  def initialize(base_url, email, api_token)
    @base_url = base_url.chomp('/')
    @email = email
    @api_token = api_token
  end

  def find_new_tickets
    jql = %(labels = "#{TRIGGER_LABEL}" AND labels != "#{IN_PROGRESS_LABEL}" AND labels != "#{IN_REVIEW_LABEL}" AND assignee = currentUser() ORDER BY created ASC)
    response = get('/rest/api/3/search/jql', jql: jql, fields: 'summary,description,assignee,labels', maxResults: 10)
    JSON.parse(response.body).fetch('issues', [])
  end

  def find_in_review_tickets
    jql = %(labels = "#{IN_REVIEW_LABEL}" AND labels != "#{IN_PROGRESS_LABEL}" AND assignee = currentUser() ORDER BY created ASC)
    response = get('/rest/api/3/search/jql', jql: jql, fields: 'summary,description,assignee,labels', maxResults: 20)
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
    req.basic_auth(@email, @api_token)
    req['Content-Type']  = 'application/json'
    req['Accept']        = 'application/json'
    req.body = body.to_json if body

    http.request(req)
  end
end
