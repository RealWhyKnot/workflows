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

## Versioning

Pin to `@v1`. That tag moves as fixes land, so every repo picks them up without a bump. Pin to a full
tag like `@v1.0.0` if you want a repo frozen.

Because `v1` moves, CI here runs every `Test-*.ps1` in the repo on both ubuntu and windows, plus
actionlint over the workflows, before I move the tag.
