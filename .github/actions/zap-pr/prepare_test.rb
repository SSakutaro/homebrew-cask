# typed: false
# frozen_string_literal: true

# Standalone tooling does not load Homebrew's Sorbet or ActiveSupport extensions.
# rubocop:disable Homebrew/NegateInclude

require "tmpdir"
require "fileutils"
require_relative "prepare"

# No test gems are needed by the workflow or local contributors.
module ZapPRTest
  def self.assert(condition, message = "assertion failed")
    raise message unless condition
  end

  def self.cask(stanza = "")
    "cask \"example\" do\n  version \"1.0\"\n  app \"Example.app\"\n#{stanza}end\n"
  end

  PATH = "~/Library/Preferences/com.example.app.plist"
  OTHER = "~/Library/Caches/com.example.app"
  FILE = "Casks/e/example.rb"
  PREFIX = "`brew generate-zap` found paths not covered by the current `zap` stanza of `example`:\n"
  ANNOTATION = {
    "path" => FILE, "title" => "Possible missing zap paths", "annotation_level" => "warning",
    "message" => "#{PREFIX}#{PATH}"
  }.freeze

  def self.test_annotations
    irrelevant = [
      ANNOTATION.merge("message" => "Unable to check `example`: timeout"),
      ANNOTATION.merge("path" => "Casks/o/other.rb"),
      ANNOTATION.merge("title" => "Other warning"),
    ]
    assert ZapPR.missing_paths([ANNOTATION, ANNOTATION, *irrelevant], "example", FILE) == [PATH]
    assert ZapPR.missing_paths(irrelevant, "example", FILE).empty?
  end

  def self.test_edits
    ["", "  # No zap stanza required\n", "  zap trash: \"#{OTHER}\"\n"].each do |stanza|
      source = cask(stanza)
      updated, paths = ZapPR.update(source, "example", [PATH])
      assert paths == [PATH]
      assert updated.include?(PATH)
      assert updated.include?(OTHER) if stanza.include?(OTHER)
      assert Prism.parse(updated).success?
      assert ZapPR.calls(Prism.parse(updated).value, :zap).length == 1
      assert !updated.include?("# No zap stanza required")
      assert ZapPR.update(updated, "example", [PATH]).nil?
    end

    source = cask("  zap quit: \"com.example.app\",\n      trash: [\n        \"#{OTHER}\",\n      ]\n")
    updated, = ZapPR.update(source, "example", [PATH])
    assert updated.include?('quit: "com.example.app"')
    assert updated.include?(OTHER)

    source = cask("  zap quit: \"com.example.app\"\n")
    updated, = ZapPR.update(source, "example", [PATH])
    assert updated.include?('quit: "com.example.app"')
    assert updated.include?(PATH)

    # Byte offsets must still be correct when earlier text is multibyte UTF-8.
    source = cask("  name \"日本語\"\n  zap trash: \"#{OTHER}\"\n")
    updated, = ZapPR.update(source, "example", [PATH])
    assert updated.force_encoding("UTF-8").include?("日本語")
  end

  def self.test_coverage
    ["trash", "delete", "rmdir"].each do |directive|
      assert ZapPR.update(cask("  zap #{directive}: \"#{PATH}\"\n"), "example", [PATH]).nil?
    end
    assert ZapPR.update(cask("  zap trash: \"~/Library/Preferences/com.example.*\"\n"), "example", [PATH]).nil?
    assert ZapPR.update(cask("  zap trash: \"~/Library/Preferences\"\n"), "example", [PATH]).nil?
    assert ZapPR.update(cask("  zap rmdir: \"~/Library/Preferences\"\n"), "example", [PATH])
    assert ZapPR.covered?("~/Library/example-*", ["~/Library/example-123"])
  end

  def self.test_manual_cases
    stanzas = [
      "  on_arm do\n    zap trash: \"#{OTHER}\"\n  end\n",
      "  on_arm do\n    # No zap stanza required\n  end\n",
      "  zap trash: \"#{OTHER}\"\n  zap trash: \"#{PATH}\"\n",
      "  zap trash: \"~/Library/\#{version}\"\n",
      "  zap trash: paths\n",
      "  zap trash: [\n    # Keep this explanation\n    \"#{OTHER}\",\n  ]\n",
    ]
    stanzas.each { |stanza| assert ZapPR.update(cask(stanza), "example", [PATH]).nil? }
    assert ZapPR.update(cask, "other", [PATH]).nil?
    assert ZapPR.update("invalid ruby {", "example", [PATH]).nil?
    assert ZapPR.update(cask, "example", []).nil?
    ["/Library/Caches/example", "~/Documents/example", "~/Library/../Documents/example",
     "~/Library/*", "~/Library/Preferences/", "~/Library/example\nrun", "~/Library/\#{system('id')}"].each do |path|
      assert ZapPR.update(cask, "example", [path]).nil?, "accepted unsafe path #{path.inspect}"
    end
    # Quoted filenames must be escaped as Ruby data, never pasted as executable source.
    path = '~/Library/Preferences/example"; system("id"); "'
    updated, = ZapPR.update(cask, "example", [path])
    zap = ZapPR.calls(Prism.parse(updated).value, :zap).first
    assert ZapPR.literal_paths(zap.arguments.arguments.first.elements.first.value) == [path]
  end

  def self.fixture
    repository = "Homebrew/homebrew-cask"
    pr = {
      "number" => 123, "merged" => true, "user" => { "login" => "BrewTestBot" },
      "head" => { "ref" => "bump-example-1.0", "sha" => "abc123", "repo" => { "full_name" => repository } },
      "base" => { "ref" => "main" }
    }
    event = { "action" => "closed", "pull_request" => pr, "repository" => { "default_branch" => "main" } }
    run = {
      "id" => 456, "conclusion" => "success", "head_sha" => "abc123", "event" => "pull_request",
      "run_number" => 1, "run_attempt" => 2, "head_repository" => { "full_name" => repository }
    }
    responses = {
      "repos/#{repository}/pulls/123" => [pr],
      "repos/#{repository}/pulls/123/files?per_page=100" => [[{ "filename" => FILE, "status" => "modified" }]],
      "repos/#{repository}/actions/workflows/ci.yml/runs?head_sha=abc123&event=pull_request&per_page=100" =>
        [{ "workflow_runs" => [run] }],
      "repos/#{repository}/actions/runs/456/attempts/2/jobs?per_page=100" => [{ "jobs" => [{
        "conclusion" => "success", "check_run_url" => "https://api.github.com/repos/#{repository}/check-runs/789"
      }] }],
      "repos/#{repository}/check-runs/789/annotations?per_page=100" => [[ANNOTATION]],
      "repos/#{repository}/pulls?state=open&per_page=100" => [[]],
    }
    [event, responses]
  end

  def self.with_fixture
    event, responses = fixture
    original_api = ZapPR.method(:api)
    # Unspecified endpoints fail the test, except the digest-derived duplicate lookup.
    ZapPR.define_singleton_method(:api) do |endpoint|
      responses.fetch(endpoint) do
        unless endpoint.include?("state=all&head=Homebrew%3Aauto-zap-example-")
          raise "Unexpected API request: #{endpoint}"
        end

        [[]]
      end
    end
    Dir.mktmpdir do |directory|
      Dir.chdir(directory) do
        FileUtils.mkdir_p([".github", "Casks/e"])
        File.write(".github/zap-pr-exclusions.json", "{}")
        File.write(FILE, cask)
        yield event, responses, directory
      end
    end
  ensure
    ZapPR.define_singleton_method(:api, original_api)
  end

  def self.test_prepare
    with_fixture do |event, _responses, directory|
      result = ZapPR.prepare(event, repository: "Homebrew/homebrew-cask", directory:)
      assert result["changes"] == "true"
      assert result["branch"].start_with?("auto-zap-example-")
      assert File.read(FILE).include?(PATH)
      body = File.read(result["body-file"])
      assert body.include?("/actions/runs/456") && body.include?("#123") && body.include?(PATH)
    end
  end

  def self.test_fork_repository
    with_fixture do |_event, _responses, directory|
      requested = []
      ZapPR.define_singleton_method(:api) do |endpoint|
        requested << endpoint
        [[]]
      end
      result = ZapPR.proposal(path: FILE, reports: [ANNOTATION], repository: "SSakutaro/homebrew-cask",
                              directory:, run_id: 456, source: "for a fork-only test")
      assert result["changes"] == "true"
      assert requested.all? { |endpoint| endpoint.start_with?("repos/SSakutaro/homebrew-cask/") }
      assert requested.any? { |endpoint| endpoint.include?("head=SSakutaro%3Aauto-zap-example-") }
      assert File.read(result["body-file"]).include?("for a fork-only test")
    end
  end

  def self.test_exclusions
    ZapPR.exclusions(File.expand_path("../../zap-pr-exclusions.json", __dir__))
    with_fixture do |event, _responses, directory|
      File.write(".github/zap-pr-exclusions.json", JSON.generate("example" => "Shared files are intentional"))
      assert ZapPR.prepare(event, repository: "Homebrew/homebrew-cask", directory:).nil?
      assert File.read(FILE) == cask
    end
    with_fixture do |_event, _responses, _directory|
      File.write(".github/zap-pr-exclusions.json", '{"example":""}')
      begin
        ZapPR.exclusions(".github/zap-pr-exclusions.json")
        raise "invalid exclusion accepted"
      rescue RuntimeError => e
        assert e.message.include?("non-empty reasons")
      end
    end
  end

  def self.test_rejected_sources
    %w[human unmerged fork other-branch failed-latest open-zap closed-zap].each do |mode|
      with_fixture do |event, responses, directory|
        case mode
        when "human" then event["pull_request"]["user"]["login"] = "someone"
        when "unmerged" then event["pull_request"]["merged"] = false
        when "fork" then event["pull_request"]["head"]["repo"]["full_name"] = "other/homebrew-cask"
        when "other-branch" then event["pull_request"]["head"]["ref"] = "auto-zap-example"
        when "failed-latest"
          page = responses.values.find { |value| value.first.is_a?(Hash) && value.first.key?("workflow_runs") }
          successful = page.first["workflow_runs"].first
          page.first["workflow_runs"] << successful.merge("run_attempt" => 3, "conclusion" => "failure")
        when "open-zap"
          responses["repos/Homebrew/homebrew-cask/pulls?state=open&per_page=100"] =
            [[{ "title" => "example: update zap stanza" }]]
        when "closed-zap"
          branch = "auto-zap-example-#{Digest::SHA256.hexdigest(PATH)[0, 12]}"
          head = URI.encode_www_form_component("Homebrew:#{branch}")
          responses["repos/Homebrew/homebrew-cask/pulls?state=all&head=#{head}&per_page=100"] =
            [[{ "state" => "closed" }]]
        end
        assert ZapPR.prepare(event, repository: "Homebrew/homebrew-cask", directory:).nil?, "accepted #{mode}"
        assert File.read(FILE) == cask
      end
    end
  end

  def self.run
    methods.grep(/^test_/).sort.each do |name|
      public_send(name)
      puts "PASS #{name}"
    end
  end
end

ZapPRTest.run

# rubocop:enable Homebrew/NegateInclude
