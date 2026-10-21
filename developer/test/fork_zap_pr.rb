# Standalone tooling is not part of Homebrew's Sorbet typechecking.
# rubocop:disable Sorbet/StrictSigil, Sorbet/TrueSigil
# typed: false
# frozen_string_literal: true

require_relative "../bin/prepare_zap_pr"

repository = ENV.fetch("GITHUB_REPOSITORY")
raise "This test only runs in the fork" if repository != "SSakutaro/homebrew-cask"
raise "Unexpected test branch" if ENV.fetch("GITHUB_REF_NAME") != "ci-auto-zap-pr-test"

run_id = ENV.fetch("SOURCE_RUN_ID")
run = ZapPR.api("repos/#{repository}/actions/runs/#{run_id}").first
raise "Source CI did not succeed" if run["conclusion"] != "success"
raise "Unexpected source workflow" if run["path"] != ".github/workflows/ci.yml"
raise "Unexpected source branch" if run["head_branch"] != ENV.fetch("GITHUB_REF_NAME")
raise "Unexpected source repository" if run.dig("head_repository", "full_name") != repository

path = "Casks/e/elephicon.rb"
source, status = Open3.capture2("git", "show", "#{ENV.fetch("GITHUB_SHA")}:#{path}")
raise "Cannot read baseline cask" unless status.success?

blob, status = Open3.capture2("git", "hash-object", "--stdin", stdin_data: source)
raise "Cannot hash baseline cask" unless status.success?

tested = ZapPR.api("repos/#{repository}/contents/#{path}?ref=#{run.fetch("head_sha")}").first
raise "Baseline cask differs from tested cask" if blob.strip != tested.fetch("sha")

reports = ZapPR.annotations(repository:, run_id:, attempt: run.fetch("run_attempt"))
paths = ZapPR.missing_paths(reports, "elephicon", path)
raise "Actual CI produced no missing zap paths" if paths.empty?
raise "Actual CI does not produce an editable proposal" unless ZapPR.update(source, "elephicon", paths)

config_path = ".github/zap-pr-exclusions.json"
original_config = File.read(config_path)
summary = ENV.fetch("GITHUB_STEP_SUMMARY")
options = { path:, reports:, repository:, directory: ENV.fetch("RUNNER_TEMP"), run_id:,
            source: "for a fork-only integration test; the destination is the test branch" }

if ARGV.first == "duplicate"
  # Use the pre-proposal file again so only PR deduplication can suppress the proposal.
  File.write(path, source)
  result = ZapPR.proposal(**options)
  raise "A duplicate proposal was generated" if result

  File.open(summary, "a") { |file| file.puts "- PASS: existing open/closed proposal suppresses duplicate creation." }
else
  begin
    excluded = JSON.parse(original_config).merge("elephicon" => "Fork test: preserve intentionally shared files")
    File.write(config_path, JSON.generate(excluded))
    result = ZapPR.proposal(**options)
    raise "Excluded cask produced a proposal" if result
    raise "Excluded cask was modified" if File.read(path) != source
  ensure
    File.write(config_path, original_config)
  end
  File.open(summary, "a") do |file|
    file.puts "## Fork integration test", "", "Source: #{run.fetch("html_url")}", "",
              "- PASS: actual CI produced #{paths.length} missing zap path(s).",
              "- PASS: cask exclusion prevents the proposal and preserves the cask."
  end

  result = ZapPR.proposal(**options)
  if result
    File.open(ENV.fetch("GITHUB_OUTPUT"), "a") do |file|
      result.each { |key, value| file.puts "#{key}=#{value}" }
    end
    File.open(summary, "a") { |file| file.puts "- PASS: production proposal code generated the cask change." }
  else
    File.open(summary, "a") { |file| file.puts "- PASS: rerun found an existing proposal; no new PR needed." }
  end
end

# rubocop:enable Sorbet/StrictSigil, Sorbet/TrueSigil
