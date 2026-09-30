# frozen_string_literal: true

require_relative "all_green"

$stdout.sync = true

sha = ARGV.fetch(0)
delay = Integer(ENV.fetch("INITIAL_DELAY", "0"))
interval = Integer(ENV.fetch("POLL_INTERVAL", "30"))
ignored = AllGreen.ignored(ENV.fetch("CONTEXT"), ENV.fetch("IGNORED", ""))
client = AllGreen::Client.new(ENV.fetch("GITHUB_REPOSITORY"), ENV.fetch("GITHUB_TOKEN"))

loop do
  sleep delay
  delay = interval

  begin
    data = AllGreen.fetch(client, sha)
    issues = AllGreen.inconsistencies(data[:suites], data[:check_runs], data[:statuses], {})
  rescue => error
    issues = ["#{error.class}: #{error.message}"]
  end

  if issues.any?
    puts "#{Time.now.utc.iso8601} inconsistent: #{issues.join("; ")}"
    next
  end

  rows = AllGreen.rows(data[:workflow_runs], data[:check_runs], data[:statuses], ignored)
  state, description = AllGreen.verdict(rows)
  puts "#{Time.now.utc.iso8601} #{state}: #{description}"
  next if state == "pending"

  rows.sort.each { |name, row_state| puts "#{row_state.to_s.ljust(8)} #{name}" }
  exit(state == "success" ? 0 : 1)
end
