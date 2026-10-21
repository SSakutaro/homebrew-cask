# Automated zap proposals

After a `BrewTestBot` bump PR from this repository's `bump-*` branches is merged,
the `zap-pr` workflow reads the latest successful CI run's check annotations and
opens a separate zap PR for human review. It uses the existing bot workflow token
and commit-signing key. It does not change the CI check or automatically merge PRs.

## Exclude a cask

Add a cask token and a reason to `.github/zap-pr-exclusions.json`, for example:

```json
{
  "example-app": "The generated paths belong to a shared component; leave them installed."
}
```

This prevents automated PRs for that cask. CI still reports possible missing paths.
The configuration is read from the default branch when the bump is merged.
The file starts empty; adding an exclusion requires the usual repository review.

## Scope and duplicate handling

- One cask per proposal, using annotations from the exact bump head SHA and latest
  CI run attempt. Failed, cancelled or incomplete runs are ignored.
- Only paths under `~/Library/` are proposed as `trash:` entries. Annotations omit
  the generated directive type, so reports containing system paths, user documents
  or unsafe path components are left for manual review.
- Only a single, unconditional zap stanza with literal path directives is edited.
  Conditional, dynamic and multiple zap stanzas are left for manual review.
- Existing `trash:`, `delete:` and `rmdir:` coverage is checked again against the
  default branch. Hand-written comments inside a replaced path list are preserved
  by skipping the automated edit.
- An existing open zap PR for the cask prevents another proposal. The deterministic
  branch includes a digest of the added paths; a closed proposal for the same paths
  is not reopened. Add an exclusion to prevent all future proposals for a cask.

Run the dependency-free tests with Ruby 3.3 or later (with bundled Prism):

```sh
ruby .github/actions/zap-pr/prepare_test.rb
```
