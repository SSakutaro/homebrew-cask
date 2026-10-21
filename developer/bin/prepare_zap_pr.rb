# Standalone tooling is not part of Homebrew's Sorbet typechecking.
# rubocop:disable Sorbet/StrictSigil, Sorbet/TrueSigil
# typed: false
# frozen_string_literal: true

# Standalone tooling does not load Homebrew's Sorbet or ActiveSupport extensions.
# rubocop:disable Homebrew/NegateInclude

require "digest"
require "json"
require "open3"
require "prism"
require "uri"

# Read CI annotations as data. Never load or evaluate a cask to edit it.
module ZapPR
  TOKEN = /\A[a-z0-9][a-z0-9+@._-]*\z/
  FLAGS = (File::FNM_CASEFOLD | File::FNM_EXTGLOB).freeze

  def self.api(endpoint)
    output, status = Open3.capture2("gh", "api", "--paginate", "--slurp", endpoint)
    raise "GitHub API failed: #{endpoint}" unless status.success?

    JSON.parse(output)
  end

  def self.literal_paths(node)
    nodes = node.is_a?(Prism::ArrayNode) ? node.elements : [node]
    return unless nodes.all?(Prism::StringNode)

    nodes.map(&:unescaped)
  end

  def self.calls(node, name)
    found = (node.is_a?(Prism::CallNode) && node.name == name) ? [node] : []
    found + node.compact_child_nodes.flat_map { |child| calls(child, name) }
  end

  def self.covered?(path, existing, rmdir: false)
    existing.any? do |entry|
      entry == path || File.fnmatch?(entry, path, FLAGS) || File.fnmatch?(path, entry, FLAGS) ||
        (!rmdir && path.downcase.start_with?("#{entry.downcase}/"))
    end
  end

  # Annotations do not retain generate-zap's trash/delete/rmdir classification.
  # Only propose user Library files; leave system paths and user documents for manual review.
  def self.safe_path?(path)
    path.is_a?(String) && path.start_with?("~/Library/") && path.length <= 1024 &&
      !path.match?(/[\x00-\x1f\x7f`\\]/) && !path.include?('#{') &&
      !path.split("/", -1).intersect?(["", ".", ".."]) &&
      path.split("/")[2..].all? { |part| part.match?(/[a-zA-Z0-9]/) }
  end

  def self.missing_paths(annotations, token, path)
    prefix = "`brew generate-zap` found paths not covered by the current `zap` stanza of `#{token}`:\n"
    matching = annotations.select do |annotation|
      annotation["path"] == path && annotation["title"] == "Possible missing zap paths" &&
        annotation["annotation_level"] == "warning" && annotation.fetch("message").start_with?(prefix)
    end
    matching.flat_map { |annotation| annotation.fetch("message").delete_prefix(prefix).lines.map(&:chomp) }.uniq.sort
  end

  def self.update(source, token, paths)
    return if paths.empty?
    return if paths.any? { |path| !safe_path?(path) }

    parsed = Prism.parse(source)
    return unless parsed.success?

    root = parsed.value.statements.body
    cask = root.first
    return if root.length != 1 || !cask.is_a?(Prism::CallNode) || cask.name != :cask
    return if !cask.block.is_a?(Prism::BlockNode) || literal_paths(cask.arguments&.arguments&.first) != [token]

    statements = cask.block.body&.body || []
    zaps = calls(parsed.value, :zap)
    # Conditional/multiple zap stanzas need a person to choose the correct scope.
    return if zaps.length > 1 || (zaps.any? && !statements.include?(zaps.first))

    source = source.b
    zap = zaps.first
    if zap
      arguments = zap.arguments&.arguments
      return if arguments&.length != 1 || !arguments.first.is_a?(Prism::KeywordHashNode)

      hash = arguments.first
      return unless hash.elements.all? do |item|
        item.is_a?(Prism::AssocNode) && item.key.is_a?(Prism::SymbolNode)
      end

      directives = hash.elements.to_h { |item| [item.key.unescaped.to_sym, item.value] }
      return if directives.length != hash.elements.length

      existing = [:trash, :delete, :rmdir].to_h do |key|
        value = directives[key] ? literal_paths(directives[key]) : []
        [key, value]
      end
      return if existing.value?(nil)

      paths = paths.reject do |path|
        covered?(path, existing[:trash] + existing[:delete]) || covered?(path, existing[:rmdir], rmdir: true)
      end
      return if paths.empty?

      value = directives[:trash]
      if value
        # Preserve hand-written explanations rather than replacing them with generated text.
        return if parsed.comments.any? do |comment|
          comment.location.start_offset.between?(value.location.start_offset, value.location.end_offset)
        end

        replacement = stanza_paths(existing[:trash] + paths)
        source[value.location.start_offset...value.location.end_offset] = replacement
      else
        source.insert(hash.location.start_offset, "trash: #{stanza_paths(paths)},\n      ")
      end
    else
      comments = parsed.comments.select { |item| item.location.slice == "# No zap stanza required" }
      return if comments.length > 1

      comment = comments.first
      return if comment && comment.location.start_column != 2

      stanza = "zap trash: #{stanza_paths(paths)}"
      if comment
        source[comment.location.start_offset...comment.location.end_offset] = stanza
      else
        source.insert(cask.block.closing_loc.start_offset, "\n  #{stanza}\n")
      end
    end

    raise "Generated invalid Ruby" unless Prism.parse(source).success?

    [source, paths]
  end

  def self.stanza_paths(paths)
    paths = paths.uniq.sort
    return paths.first.dump if paths.length == 1

    "[\n#{paths.map { |path| "    #{path.dump},\n" }.join}  ]"
  end

  def self.exclusions(file)
    config = JSON.parse(File.read(file))
    raise "Zap PR exclusions must be a JSON object" unless config.is_a?(Hash)

    unless config.all? do |token, reason|
      token.match?(TOKEN) && reason.is_a?(String) && !reason.strip.empty?
    end
      raise "Zap PR exclusions must map cask tokens to non-empty reasons"
    end

    config
  end

  def self.excluded?(token)
    reason = exclusions(".github/zap-pr-exclusions.json")[token]
    return false unless reason

    puts "Skipping #{token}: #{reason}"
    true
  end

  def self.prepare(event, repository:, directory:)
    pr = event.fetch("pull_request")
    return if event["action"] != "closed" || !pr["merged"] || pr.dig("user", "login") != "BrewTestBot"
    return if pr.dig("head", "repo", "full_name") != repository || !pr.dig("head", "ref").start_with?("bump-")
    return if pr.dig("base", "ref") != event.dig("repository", "default_branch")

    # Re-read PR state rather than trusting a caller-provided event payload.
    current = api("repos/#{repository}/pulls/#{pr.fetch("number")}").first
    return if !current["merged"] || current.dig("user", "login") != "BrewTestBot"
    return if current.dig("head", "sha") != pr.dig("head", "sha")

    files = api("repos/#{repository}/pulls/#{pr.fetch("number")}/files?per_page=100").flatten
    casks = files.select { |file| file["filename"].match?(%r{\ACasks/[a-z0-9]/[^/]+\.rb\z}) }
    return if casks.length != 1 || casks.first["status"] != "modified"

    path = casks.first.fetch("filename")
    token = File.basename(path, ".rb")
    return unless token.match?(TOKEN)
    return if path != "Casks/#{token[0]}/#{token}.rb"

    return if excluded?(token)

    sha = pr.dig("head", "sha")
    runs = api("repos/#{repository}/actions/workflows/ci.yml/runs?head_sha=#{sha}&event=pull_request&per_page=100")
           .flat_map { |page| page.fetch("workflow_runs") }
    run = runs.max_by { |item| [item.fetch("run_number"), item.fetch("run_attempt")] }
    # Do not fall back to stale results if the latest run failed or was cancelled.
    return unless run
    return if run["conclusion"] != "success" || run["head_sha"] != sha
    return if run["event"] != "pull_request" || run.dig("head_repository", "full_name") != repository

    reports = annotations(repository:, run_id: run.fetch("id"), attempt: run.fetch("run_attempt"))
    proposal(path:, reports:, repository:, directory:, run_id: run.fetch("id"),
             source: "for the merged bump PR ##{pr.fetch("number")}")
  end

  def self.annotations(repository:, run_id:, attempt:)
    run_endpoint = "repos/#{repository}/actions/runs/#{run_id}/attempts/#{attempt}"
    jobs = api("#{run_endpoint}/jobs?per_page=100")
           .flat_map { |page| page.fetch("jobs") }
    jobs.select { |job| job["conclusion"] == "success" }.flat_map do |job|
      check = job.fetch("check_run_url").delete_prefix("https://api.github.com/")
      raise "Unexpected check URL" unless check.match?(%r{\Arepos/#{Regexp.escape(repository)}/check-runs/\d+\z})

      api("#{check}/annotations?per_page=100").flatten
    end
  end

  def self.proposal(path:, reports:, repository:, directory:, run_id:, source:)
    token = File.basename(path, ".rb")
    return unless token.match?(TOKEN)
    return if path != "Casks/#{token[0]}/#{token}.rb"
    return if excluded?(token)

    paths = missing_paths(reports, token, path)
    result = update(File.read(path), token, paths)
    return unless result

    content, additions = result
    branch = "auto-zap-#{token}-#{Digest::SHA256.hexdigest(additions.sort.join("\n"))[0, 12]}"
    # A rejected/closed proposal with the same paths must not be opened repeatedly.
    owner = repository.split("/").first
    head = URI.encode_www_form_component("#{owner}:#{branch}")
    previous = api("repos/#{repository}/pulls?state=all&head=#{head}&per_page=100").flatten
    unless previous.empty?
      puts "Skipping #{token}: a proposal for these paths already exists (open or closed)."
      return
    end

    open_prs = api("repos/#{repository}/pulls?state=open&per_page=100").flatten
    return if open_prs.any? do |item|
      item.fetch("title").match?(/\A#{Regexp.escape(token)}(?:\s|:)/i) && item.fetch("title").match?(/\bzap\b/i)
    end

    File.write(path, content)
    body_file = File.join(directory, "zap-pr-body.md")
    File.write(body_file, <<~MARKDOWN)
      Add paths reported by [CI](https://github.com/#{repository}/actions/runs/#{run_id})
      #{source}.

      #{additions.map { |item| "- `#{item}`" }.join("\n")}

      These are generated candidates and need human review before merging.
      Casks can be excluded with a reason in `.github/zap-pr-exclusions.json`.

      Created automatically by the `zap-pr` workflow using `brew generate-zap` CI results.
    MARKDOWN
    { "cask-path" => path, "token" => token, "branch" => branch, "body-file" => body_file, "changes" => "true" }
  end
end

# rubocop:enable Sorbet/StrictSigil, Sorbet/TrueSigil, Homebrew/NegateInclude

if $PROGRAM_NAME == __FILE__
  event = JSON.parse(File.read(ENV.fetch("GITHUB_EVENT_PATH")))
  outputs = ZapPR.prepare(event, repository: ENV.fetch("GITHUB_REPOSITORY"), directory: ENV.fetch("RUNNER_TEMP"))
  if outputs
    File.open(ENV.fetch("GITHUB_OUTPUT"), "a") do |file|
      outputs.each { |key, value| file.puts "#{key}=#{value}" }
    end
  else
    puts "No eligible zap changes."
  end
end
