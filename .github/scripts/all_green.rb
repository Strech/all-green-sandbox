# frozen_string_literal: true

require "json"
require "net/http"
require "time"

module AllGreen
  PASSING = %w[success skipped neutral].freeze
  DESCRIPTION_LIMIT = 140
  RETRY_DELAYS = [5, 10, 20, 30, 60].freeze

  module_function

  def latest(check_runs)
    check_runs
      .group_by { |run| [run.dig("app", "id"), run["name"]] }
      .map { |_, runs| runs.max_by { |run| run["id"] } }
  end

  def check_run_state(run)
    return :pending unless run["status"] == "completed" && run["conclusion"]

    PASSING.include?(run["conclusion"]) ? :success : :failure
  end

  def status_state(status)
    case status["state"]
    when "pending" then :pending
    when "success" then :success
    else :failure
    end
  end

  def rows(check_runs, statuses, ignored)
    rows = latest(check_runs).map { |run| [run["name"], check_run_state(run)] } +
      statuses.map { |status| [status["context"], status_state(status)] }

    rows.reject { |name, _| ignored.any? { |pattern| pattern.match?(name) } }
  end

  def verdict(rows)
    failing = rows.select { |_, state| state == :failure }.map(&:first)
    pending = rows.select { |_, state| state == :pending }.map(&:first)

    if failing.any?
      ["failure", truncate("Failing: #{failing.join(", ")}")]
    elsif pending.any?
      ["pending", truncate("Waiting for #{pending.size}: #{pending.join(", ")}")]
    else
      ["success", "All #{rows.size} checks passed"]
    end
  end

  def inconsistencies(suites, check_runs, statuses, trigger)
    issues = []

    if trigger[:suite_id]
      suite = suites.find { |candidate| candidate["id"] == trigger[:suite_id] }
      issues << "triggering suite #{trigger[:suite_id]} is #{suite ? suite["status"] : "missing"}" unless suite&.fetch("status") == "completed"
    end

    if trigger[:context]
      status = statuses.find { |candidate| candidate["context"] == trigger[:context] }
      issues << "status #{trigger[:context]} is older than event #{trigger[:status_id]}" unless status && status["id"] >= trigger[:status_id]
    end

    suites.select { |suite| suite["status"] == "completed" }.each do |suite|
      runs = latest(check_runs.select { |run| run.dig("check_suite", "id") == suite["id"] })
      incomplete = runs.reject { |run| run["status"] == "completed" && run["conclusion"] }

      issues << "suite #{suite["id"]} completed, but not: #{incomplete.map { |run| run["name"] }.join(", ")}" if incomplete.any?
      issues << "suite #{suite["id"]} completed with #{runs.size}/#{suite["latest_check_runs_count"]} check runs" if runs.size < suite["latest_check_runs_count"]
    end

    issues
  end

  def truncate(text)
    (text.size > DESCRIPTION_LIMIT) ? "#{text[0, DESCRIPTION_LIMIT - 1]}…" : text
  end

  class Client
    def initialize(repo, token)
      @repo = repo
      @token = token
    end

    def all(path, key)
      uri = URI("https://api.github.com/repos/#{@repo}/#{path}")
      items = []

      while uri
        response = request(Net::HTTP::Get.new(uri))
        items.concat(JSON.parse(response.body).fetch(key))
        uri = next_page(response["link"])
      end

      items
    end

    def post(path, body)
      http = Net::HTTP::Post.new(URI("https://api.github.com/repos/#{@repo}/#{path}"))
      http.body = JSON.generate(body)
      request(http)
    end

    private

    def request(http)
      http["Authorization"] = "Bearer #{@token}"
      http["Accept"] = "application/vnd.github+json"
      http["X-GitHub-Api-Version"] = "2022-11-28"

      response = Net::HTTP.start(http.uri.host, http.uri.port, use_ssl: true) { |connection| connection.request(http) }
      raise "#{http.method} #{http.uri} → #{response.code}: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

      response
    end

    def next_page(link)
      link&.split(",")&.find { |part| part.include?('rel="next"') }&.then { |part| URI(part[/<([^>]+)>/, 1]) }
    end
  end
end

if $PROGRAM_NAME == __FILE__
  $stdout.sync = true

  repo = ENV.fetch("GITHUB_REPOSITORY")
  sha = ARGV.fetch(0)
  context = ENV.fetch("CONTEXT", "all-jobs-are-green")
  ignored = [/\A#{Regexp.escape(context)}\z/] +
    ENV.fetch("IGNORED", "").split("\n").map(&:strip).reject(&:empty?).map { |pattern| /\A#{pattern}\z/ }
  trigger = {
    suite_id: ENV["TRIGGER_SUITE_ID"].to_s.empty? ? nil : Integer(ENV["TRIGGER_SUITE_ID"]),
    context: ENV["TRIGGER_CONTEXT"].to_s.empty? ? nil : ENV["TRIGGER_CONTEXT"],
    status_id: ENV["TRIGGER_STATUS_ID"].to_i
  }

  client = AllGreen::Client.new(repo, ENV.fetch("GITHUB_TOKEN"))
  delays = AllGreen::RETRY_DELAYS.dup
  suites = check_runs = statuses = issues = nil

  loop do
    suites = client.all("commits/#{sha}/check-suites?per_page=100", "check_suites")
    check_runs = client.all("commits/#{sha}/check-runs?filter=all&per_page=100", "check_runs")
    statuses = client.all("commits/#{sha}/status?per_page=100", "statuses")
    issues = AllGreen.inconsistencies(suites, check_runs, statuses, trigger)

    break if issues.empty? || delays.empty?

    delay = delays.shift
    puts "#{Time.now.utc.iso8601} stale read, retrying in #{delay}s:"
    issues.each { |issue| puts "  #{issue}" }
    sleep delay
  end

  rows = AllGreen.rows(check_runs, statuses, ignored)
  state, description = AllGreen.verdict(rows)

  rows.sort.each { |name, row_state| puts "#{row_state.to_s.ljust(8)} #{name}" }
  puts "=> #{state}: #{description}"

  unless ENV["DRY_RUN"]
    client.post("statuses/#{sha}", {
      state: state,
      context: context,
      description: description,
      target_url: "#{ENV.fetch("GITHUB_SERVER_URL", "https://github.com")}/#{repo}/actions/runs/#{ENV["GITHUB_RUN_ID"]}"
    })
  end

  if issues.any?
    puts "::error::still inconsistent after retries: #{issues.join("; ")}"
    exit 1
  end
end
