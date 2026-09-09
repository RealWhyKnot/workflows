# workflows

Shared GitHub Actions I use across my own repos, so a fix lands once instead of in a dozen copies.

## Reusable workflows

These replace a whole job. Call one and the runner, timeout and checkout come with it:

```yaml
name: Commit message check

on:
  push:
    branches: [main]
  pull_request:

permissions:
  contents: read

jobs:
  check:
    uses: RealWhyKnot/workflows/.github/workflows/commit-msg-check.yml@v1
```

Set `permissions` on the calling job, not here. A called workflow can only keep or drop what the
caller granted, never add to it, so a missing permission shows up as a 403 deep inside the run.

| workflow | what it does | needs |
| --- | --- | --- |
| `commit-msg-check.yml` | Rejects commit subjects with more than one CalVer build stamp, optionally also non-conventional subjects and bodies matching a forbidden pattern. | `contents: read` |
| `wiki-sync.yml` | Mirrors `wiki/` into the repo's GitHub Wiki. Skips quietly until someone creates the first wiki page. | `contents: write` |
| `version-guard.yml` | Fails if a `const string Version` reappears in `Editor/` or `Runtime/`. | `contents: read` |
| `dependabot-automerge.yml` | Turns on auto-merge for Dependabot updates of an allowed type. | `contents: write`, `pull-requests: write` |
| `changelog-append.yml` | Runs your `Update-Changelog.ps1` over the pushed range and commits the result back, signed. | `contents: write` |
| `nightly-beta.yml` | Tags a beta when main has moved since the last tag. | `contents: write` |
| `nightly-beta-scripted.yml` | Same, but your own planner script decides the tag. | `contents: write`, `actions: write` |

`commit-msg-check.yml` inputs, all optional:

| input | default | meaning |
| --- | --- | --- |
| `check-stamp` | `true` | Count build stamps per subject and fail on more than one. |
| `stamp-pattern` | `\([0-9]{4}\.[0-9]+\.[0-9]+\.[0-9]+(-([A-Fa-f0-9]{4}\|beta))?\)` | What one stamp looks like. |
| `check-conventional` | `false` | Also require conventional subjects. |
| `conventional-pattern` | `feat\|fix\|chore\|ci\|docs\|refactor\|test\|perf\|diag\|style` | Which types count. |
| `forbidden-body-pattern` | none | Rejected anywhere in a non-merge commit body. I use it to keep upstream issue numbers out of a fork's history. |

Merge and revert subjects skip the conventional and body checks, because a merge subject is never
going to be a conventional commit. They are still counted for stamps.

`wiki-sync.yml` takes `source-dir` (default `wiki`) and `exclude` (newline-separated, default
`README.md`). `version-guard.yml` takes `error-hint`, appended to the failure message so it can name
the pattern to use instead. `dependabot-automerge.yml` takes `update-types` (newline-separated,
default `version-update:semver-patch`) and `merge-method` (default `rebase`).

Dependabot hands its workflows a read-only token, so the write permissions above have to be spelled
out on the calling job or the merge call fails.

## release-notes

Builds release notes from conventional commits and writes them to a file for `gh release create`.

```yaml
- name: Build release notes
  id: notes
  uses: RealWhyKnot/workflows/release-notes@v1
  with:
    tag: ${{ steps.release_tag.outputs.tag }}
    title: My App ${{ steps.release_tag.outputs.tag }}

- name: Create release
  env:
    GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
  run: gh release create '${{ steps.release_tag.outputs.tag }}' --notes-file '${{ steps.notes.outputs.file }}'
```

| input | default | meaning |
| --- | --- | --- |
| `tag` | required | The tag being released. |
| `repository` | the calling repo | `owner/name` to read commits from. |
| `previous-tag` | resolved | What to diff against. A stable tag diffs against the last stable; a prerelease diffs against whatever came before it. |
| `title` | none | An H1 above the changes. |
| `extra` | none | Markdown appended after the changelog, for downloads and hashes. |

The only output is `file`, the path to the generated markdown.

Commits are bucketed by conventional-commit prefix into Breaking Changes, Features, Bug Fixes,
Performance, Changes, Documentation, Build, CI, Tests, Chores and Other. A `type!:` subject goes to
Breaking Changes. Merge commits and anything carrying `[skip changelog]` are dropped, and a trailing
CalVer build stamp like `(2026.9.7.1-A528)` is stripped from the subject.

Authors are resolved to real GitHub handles through the commits API, so outside contributors and
`@dependabot[bot]` get credited properly. It falls back to `git log` and the raw commit author name
if the API is unreachable, which is also what happens for a first release with nothing to diff
against. That needs `GH_TOKEN`; the action passes `github.token` for you.

Requires `fetch-depth: 0` and `fetch-tags: true` on the checkout, or there is no history to read.

## commit-subjects

The check behind `commit-msg-check.yml`, if you want it as a step inside a job you already have.
Same inputs, plus `range` to override the range it works out from the triggering event. It needs a
checkout with `fetch-depth: 0`.

```yaml
- uses: RealWhyKnot/workflows/commit-subjects@v1
  with:
    check-conventional: true
```

## resolve-tag

Validates the tag being released and tells you what it is.

```yaml
- id: tag
  uses: RealWhyKnot/workflows/resolve-tag@v1
  with:
    tag: ${{ inputs.tag }}
```

With no `tag` it falls back to the ref that triggered the run, so the same step covers a tag push and
a manual re-release. Outputs `tag`, `version` (the tag without its `v`), `prerelease`, `channel`
(`beta` or `release`) and `sha`, the commit the tag points at.

| input | default | meaning |
| --- | --- | --- |
| `tag` | the triggering ref | Tag to release. |
| `tag-pattern` | `^v\d{4}\.\d+\.\d+\.\d+(-([A-Fa-f0-9]{4}\|beta))?$` | What a valid tag looks like. |
| `prerelease-pattern` | `-beta` only | Which tags count as prereleases. Widen it if every suffix should. |
| `require-tag-exists` | `true` | Fail unless the tag resolves to a commit in the checkout. |

The two patterns are separate on purpose: a `-A1B2` tag is valid but is not a beta, and I have repos
that want it either way.

## publish-release

Creates the release, uploads the assets, and optionally checks the upload landed.

```yaml
- uses: RealWhyKnot/workflows/publish-release@v1
  with:
    tag: ${{ steps.tag.outputs.tag }}
    notes-file: ${{ steps.notes.outputs.file }}
    prerelease: ${{ steps.tag.outputs.prerelease }}
    assets: |
      dist/app.zip
      dist/app.zip.sha256
```

An asset entry containing `*` or `?` is expanded, so `dist/python/*` works and a glob that matches
nothing simply contributes no assets.

`prerelease: true` adds `--prerelease --latest=false`. `draft-first: true` creates a draft, confirms
every asset actually attached, and only then promotes it, which is what you want when a failed upload
would otherwise publish an empty release. `delete-existing: true` replaces an existing release for
the tag. Give it `verify-asset` and `verify-sha256` together and it polls the API until the uploaded
digest matches, because an upload can report success before the asset is readable.

Cleaning up a half-made release stays in your workflow, since it needs to run on failure:

```yaml
- name: Remove a partial release
  if: failure()
  run: gh release delete ${{ steps.tag.outputs.tag }} --yes 2>$null; $global:LASTEXITCODE = 0
  shell: pwsh
```

## commit-on-branch

Commits files back to a branch through the GraphQL `createCommitOnBranch` mutation instead of
`git push`. GitHub signs those commits server-side, so they satisfy a "commits must have verified
signatures" rule, which a plain push from Actions does not.

```yaml
- uses: RealWhyKnot/workflows/commit-on-branch@v1
  with:
    headline: 'docs(changelog): promote Unreleased to ${{ steps.tag.outputs.tag }} [skip changelog]'
    paths: |
      CHANGELOG.md
```

It reads the branch head itself and sends it as `expectedHeadOid`, so a racing commit fails the
mutation rather than silently clobbering. By default it does nothing when the files already match the
branch, and fails if GitHub does not report the new commit as verified. Set `warn-on-failure: true`
where a missed changelog commit should not fail the release.

A commit made with `GITHUB_TOKEN` does not trigger workflows, which is what stops the changelog
commit from re-running the job that made it.

## changelog-append

Calls your repo's `Update-Changelog.ps1 -Mode Append -Range ...`, then commits whatever changed
through `commit-on-branch`, so the commit is signed and clears a required-signatures rule.

```yaml
jobs:
  append:
    if: ${{ github.event_name == 'workflow_dispatch' || (github.actor != 'github-actions[bot]' && !contains(github.event.head_commit.message, '[skip changelog]')) }}
    uses: RealWhyKnot/workflows/.github/workflows/changelog-append.yml@v1
    with:
      range: ${{ inputs.range }}
```

Keep the recursion guard on your own job: a commit made with `GITHUB_TOKEN` does not trigger
workflows, but a manual re-run or a different actor can still loop. `changelog-paths` takes a
newline-separated list for repos that also keep `wiki/Changelog.md`, and `trigger-wiki-sync: true`
kicks the wiki afterwards, since the changelog commit will not fire the wiki's push trigger.

## nightly-beta

Tags `vYYYY.M.D.N-beta` when main has moved since the newest tag, and does nothing when it has not.
The date comes from `timezone` (default `America/Chicago`), not UTC, so a late-evening commit still
lands on the right day.

```yaml
jobs:
  tag:
    uses: RealWhyKnot/workflows/.github/workflows/nightly-beta.yml@v1
  release:
    needs: tag
    if: needs.tag.outputs.tag != ''
    permissions:
      contents: write
    uses: ./.github/workflows/release.yml
    with:
      tag: ${{ needs.tag.outputs.tag }}
```

The release job stays in your repo: `./` inside a shared workflow would resolve to this repository,
not yours. If your `release.yml` only triggers on a tag push, set `dispatch-release: true` instead
and drop the second job, because a tag pushed with `GITHUB_TOKEN` never fires that trigger.

`nightly-beta-scripted.yml` is the same shape for repos whose own planner decides the tag. It runs
`.github/scripts/Get-NightlyBetaPlan.ps1` and expects `has_changes` and `next_tag` outputs from it.

## hooks

`commit-msg` rejects a subject carrying more than one build stamp, and `prepare-commit-msg` appends
the current one. They live here so the pattern matches `commit-msg-check.yml` exactly; a test in
this repo fails if the two ever drift apart.

```
pwsh path/to/workflows/hooks/Install-Hooks.ps1 -RepoRoot .
```

That copies both into `.githooks/` and points `core.hooksPath` at it. It refuses to overwrite a hook
you have changed unless you pass `-Force`. `pre-push` is deliberately not shared: every repo drives a
different linter from it.

## Versioning

Pin to `@v1`. That tag moves as fixes land, so every repo picks them up without a bump. Pin to a full
tag like `@v1.0.0` if you want a repo frozen.

Because `v1` moves, CI here runs every `Test-*.ps1` in the repo on both ubuntu and windows, plus
actionlint over the workflows, before I move the tag.
