# workflows

[![CI](https://github.com/RealWhyKnot/workflows/actions/workflows/ci.yml/badge.svg)](https://github.com/RealWhyKnot/workflows/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/RealWhyKnot/workflows)](https://github.com/RealWhyKnot/workflows/releases)

The GitHub Actions, reusable workflows, git hooks and lint configs that my repos share.

## Picking a version

| ref | points to |
| --- | --- |
| `@v1` | latest release, and what all my repos use |
| `@v2026.10.28.0` | that release. Change the tag when you want to upgrade or roll back. |
| `@<commit sha>` | that commit |

If you use these from your own repo, pin a release tag. [Versioning](#versioning) has the details,
and each release on the [releases page](https://github.com/RealWhyKnot/workflows/releases) lists
what changed.

## Contents

| workflow | what it does |
| --- | --- |
| [`commit-msg-check.yml`](#commit-msg-checkyml) | Checks commit subjects for build stamps, and optionally for conventional types and forbidden body text |
| [`version-guard.yml`](#version-guardyml) | Fails if a `const string Version` comes back in `Editor/` or `Runtime/` |
| [`dependabot-automerge.yml`](#dependabot-automergeyml) | Auto-merge for the Dependabot updates you allow |
| [`repo-checks.yml`](#repo-checksyml) | `workflow-syntax`, `conformance` and actionlint |
| [`changelog-append.yml`](#changelog-append) | Runs your changelog script on a push and commits the result as a signed commit |
| [`nightly-beta.yml`](#nightly-beta) | Tags a nightly beta when main has changed since the last tag |
| [`nightly-beta-scripted.yml`](#nightly-beta) | Same, but your own script picks the tag |

| group | actions |
| --- | --- |
| Releases | [`resolve-tag`](#resolve-tag), [`version-sequence`](#version-sequence), [`release-notes`](#release-notes), [`checksums`](#checksums), [`publish-release`](#publish-release), [`commit-on-branch`](#commit-on-branch) |
| Nightly betas | [`beta-gate`](#beta-gate), [`nightly-plan`](#nightly-plan), [`wait-for-ci`](#wait-for-ci) |
| Repo checks | [`commit-subjects`](#commit-subjects), [`workflow-syntax`](#workflow-syntax), [`conformance`](#conformance) |
| Setup | [`setup-rust`](#setup-rust), [`setup-nsis`](#setup-nsis) |

The repo also has my [git hooks](#hooks), [lint baselines](#lint) and a starting
[Dependabot config](#dependabot).

## Reusable workflows

Each one sets its own runner and timeout. You call it with a `uses:` line in a job of your own.

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

A called workflow only gets the permissions its caller grants, and a step that needs more fails with
a 403.

| workflow | permissions |
| --- | --- |
| `commit-msg-check.yml`, `version-guard.yml`, `repo-checks.yml` | `contents: read` |
| `dependabot-automerge.yml` | `contents: write`, `pull-requests: write` |
| `changelog-append.yml` | `contents: write` |
| `nightly-beta.yml` | `contents: write`, plus `actions: read` for `ci-workflow` and `actions: write` for `dispatch-release` |
| `nightly-beta-scripted.yml` | `contents: write`, `actions: write` |

Runs that Dependabot triggers get a read-only token. If your job doesn't grant
`dependabot-automerge.yml` the permissions in the table, its merge call fails.

### commit-msg-check.yml

Fails when a commit subject has more than one CalVer build stamp. It can also require conventional
subjects, and reject commit bodies that match a pattern. All inputs are optional.

| input | default | description |
| --- | --- | --- |
| `check-stamp` | `true` | Fail on a subject with more than one build stamp |
| `stamp-pattern` | `\([0-9]{4}\.[0-9]+\.[0-9]+\.[0-9]+(-([A-Fa-f0-9]{4}\|beta))?\)` | Regex for one stamp |
| `check-conventional` | `false` | Also require conventional subjects |
| `conventional-pattern` | `^(feat\|fix\|chore\|ci\|docs\|refactor\|revert\|test\|perf\|diag\|style)(\([a-z0-9-]+\))?!?: .+` | Regex for a conventional subject |
| `forbidden-body-pattern` | none | Fail any non-merge commit whose body matches. I use it in forks to keep upstream issue numbers out of the history. |

Merge and revert commits still have their stamps counted but skip the conventional and body checks.

### version-guard.yml

Its one input is `error-hint`, which is added to the failure message. It defaults to
`Use PackageInfo.FindForAssembly() instead.`

### dependabot-automerge.yml

Turns on auto-merge for Dependabot PRs whose update type you allow.

| input | default | description |
| --- | --- | --- |
| `update-types` | `version-update:semver-patch` | Update types allowed to auto-merge, one per line |
| `merge-method` | `rebase` | `merge`, `squash` or `rebase` |

### repo-checks.yml

Runs [`workflow-syntax`](#workflow-syntax), [`conformance`](#conformance) and actionlint (with
shellcheck). My repos all call it from CI.

| input | default | description |
| --- | --- | --- |
| `pins` | `warn` | Passed to `conformance` |
| `ignore-ecosystems` | none | Passed to `conformance` |
| `actionlint` | `true` | Run actionlint and shellcheck on the workflows |

## Releases

### resolve-tag

Validates the tag being released and outputs its version, commit, and whether it's a prerelease.

```yaml
- id: tag
  uses: RealWhyKnot/workflows/resolve-tag@v1
  with:
    tag: ${{ inputs.tag }}
```

With no `tag` it uses the ref that triggered the run. The same step then works for a tag push and
for a manual re-release.

| input | default | description |
| --- | --- | --- |
| `tag` | triggering ref | Tag to release |
| `tag-pattern` | `^v\d{4}\.\d+\.\d+\.\d+(-([A-Fa-f0-9]{4}\|beta))?$` | Regex for a valid tag |
| `prerelease-pattern` | `-beta` only | Regex for prerelease tags. Widen it if other suffixes should count too. |
| `require-tag-exists` | `true` | Fail unless the tag resolves to a commit in the checkout |

| output | description |
| --- | --- |
| `tag` | The tag |
| `version` | The tag minus its leading `v` |
| `prerelease` | `true` if the tag matches `prerelease-pattern` |
| `channel` | `beta` for a prerelease, else `release` |
| `sha` | Commit the tag points at (empty when `require-tag-exists` is off) |

There are two patterns because a tag ending in `-A1B2` is valid without being a beta. My repos treat
it differently.

### version-sequence

A CalVer tag has to use the next free revision for its day, or this fails.

```yaml
- uses: RealWhyKnot/workflows/version-sequence@v1
  with:
    tag: ${{ steps.tag.outputs.tag }}
```

| input | default | description |
| --- | --- | --- |
| `tag` | required | Tag being released |
| `prerelease-suffix` | `[A-Za-z0-9]{4}` | Regex for the part after the hyphen. Only used to decide if the tag is valid. |
| `repo-root` | workspace | Repo to read tags from |

Each day starts at `.0`. After that a tag has to be one above the highest tag from the same day,
whatever its suffix. Re-running a release for an existing tag still passes, because the tag under
test is left out of the count. You need `fetch-depth: 0` on the checkout to see the earlier tags.

The default suffix allows `-beta` and `-A1B2` but not `-rc.1`. In repos that use any suffix I pass
`[A-Za-z0-9][A-Za-z0-9.-]*`.

### release-notes

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

| input | default | description |
| --- | --- | --- |
| `tag` | required | Tag being released |
| `repository` | calling repo | `owner/name` to read commits from |
| `previous-tag` | worked out | Tag to diff against. For a stable tag that's the previous stable tag; for a prerelease, whichever tag came just before. |
| `title` | none | H1 above the changes |
| `extra` | none | Markdown appended after the changelog (downloads, hashes) |

The one output, `file`, is the path of the Markdown it wrote. You need `fetch-depth: 0` and
`fetch-tags: true` on the checkout, or it has no history to read.

Commits are grouped by prefix into Breaking Changes, Features, Bug Fixes, Performance, Changes,
Documentation, Build, CI, Tests, Chores and Other, with any `type!:` subject under Breaking Changes.
Merge commits and anything marked `[skip changelog]` are dropped, and a CalVer stamp at the end of a
subject (e.g. `(2026.9.7.1-A528)`) is stripped off.

Each author gets a link to their GitHub profile, which doesn't notify them. A bare `@handle` would
ping them and put them in the release's Contributors avatars, and in a fork that would credit
upstream authors who haven't contributed to my repo. Bots like `dependabot[bot]` are plain text.

Logins come from the commits API, which knows outside contributors' logins too. The action sets the
`GH_TOKEN` it needs to `github.token` for you. If the API can't be reached it falls back to
`git log` and the raw author name. On a first release the notes list all commits up to the tag.

### checksums

Hashes release archives, writes an integrity manifest next to each, and returns a Markdown table for
the release notes.

```yaml
- name: Checksums
  id: checksums
  uses: RealWhyKnot/workflows/checksums@v1
  with:
    archives: |
      dist/*.zip
      dist/*.tar.gz
    contents: dist/publish
```

| input | default | description |
| --- | --- | --- |
| `archives` | required | Paths or globs, one per line. A pattern with no match fails the job, for instance after an artifact is renamed. |
| `contents` | sibling | Directory whose files are listed in the manifest after the archive's own row. If unset, it's the folder next to each archive with the same base name. |
| `manifest-suffix` | `.integrity.tsv` | Suffix for the file written next to each archive |
| `manifest` | `true` | `false` returns the table without writing any manifests |
| `units` | `MiB` | `MiB` (1048576 bytes) or `MB` (1000000). The table header says which. |
| `table-file` | none | Also write the table to this path |

| output | description |
| --- | --- |
| `sha256` | SHA-256 of the first archive |
| `manifests` | Paths of the manifests written, one per line |
| `table` | The Markdown table |

A manifest is a tab-separated file with no header and one `hash  bytes  name` line per file, archive
first. Hashes are lowercase. `.tar.gz` drops both extensions (`app-1.0.0.tar.gz` gets
`app-1.0.0.integrity.tsv`).

Hash on the runner that built the archives and read the manifests later. VRCFaceTracking published
wrong hashes for three releases because it downloaded a release asset to hash it, and
`Start-Process gh api -RedirectStandardOutput` re-encodes a binary stream instead of copying the
bytes.

### publish-release

Creates the release, uploads the assets, and can check that the upload worked.

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

| input | default | description |
| --- | --- | --- |
| `tag` | required | Tag to publish |
| `title` | tag | Release title |
| `notes-file` | none | Path to the Markdown notes |
| `assets` | none | Files to upload, one per line. Globs like `dist/python/*` work, and one that matches nothing is skipped. |
| `repository` | calling repo | `owner/name` to publish to |
| `target` | none | Commit-ish for the release |
| `prerelease` | `false` | Adds `--prerelease --latest=false` |
| `draft-first` | `false` | Create a draft, check that all assets are attached, then publish |
| `delete-existing` | `false` | If the tag already has a release, delete it first |
| `verify-asset` | none | Asset whose digest is checked after upload |
| `verify-sha256` | none | Expected SHA-256 of that asset |

Turn on `draft-first` anywhere a failed upload would otherwise leave an empty release published. If
a re-run finds a draft for the tag, such as one from a failed run, it checks that draft's assets and
publishes it the same way.

With both `verify-asset` and `verify-sha256` set, it polls the API until the uploaded asset's digest
matches, since an upload can report success before the asset is readable.

To clean up a half-made release, add a step to your workflow that runs on failure.

```yaml
- name: Remove a partial release
  if: failure()
  run: gh release delete ${{ steps.tag.outputs.tag }} --yes 2>$null; $global:LASTEXITCODE = 0
  shell: pwsh
```

### commit-on-branch

Commits files to a branch with the GraphQL `createCommitOnBranch` mutation. GitHub signs those
commits. That gets them past a required-signatures rule, which a plain `git push` from Actions would
fail.

```yaml
- uses: RealWhyKnot/workflows/commit-on-branch@v1
  with:
    headline: 'docs(changelog): promote Unreleased to ${{ steps.tag.outputs.tag }} [skip changelog]'
    paths: |
      CHANGELOG.md
```

| input | default | description |
| --- | --- | --- |
| `paths` | required | Files to commit, one per line, relative to the workspace |
| `headline` | required | Commit subject |
| `body` | none | Commit body |
| `branch` | `main` | Branch to commit to |
| `repository` | calling repo | `owner/name` to commit to |
| `skip-if-unchanged` | `true` | Do nothing if the files already match the branch |
| `verify-signature` | `true` | Fail unless GitHub marks the new commit verified |
| `warn-on-failure` | `false` | Warn instead of failing the job, for when a missed changelog commit shouldn't fail a release |

It reads the branch head and sends it as `expectedHeadOid`. If another commit reached the branch in
between, GitHub rejects the mutation.

Because commits made with `GITHUB_TOKEN` don't trigger workflows, the changelog commit doesn't
re-run the job that made it.

### changelog-append

`changelog-append.yml` calls your repo's changelog script with `-Mode Append -Range ...` and commits
whatever changed through `commit-on-branch`, which signs it.

```yaml
jobs:
  append:
    if: >-
      ${{ github.event_name == 'workflow_dispatch' ||
      (github.actor != 'github-actions[bot]' &&
      !contains(github.event.head_commit.message, '[skip changelog]')) }}
    uses: RealWhyKnot/workflows/.github/workflows/changelog-append.yml@v1
    with:
      range: ${{ inputs.range }}
```

| input | default | description |
| --- | --- | --- |
| `range` | the push | Commit range to append |
| `changelog-paths` | `CHANGELOG.md` | Changelog files the script maintains, one per line |
| `script` | `./.github/scripts/Update-Changelog.ps1` | Script that appends the entries |

Keep the `if:` guard on your job. A manual re-run or a commit from another actor can still start a
loop.

## Nightly betas

### nightly-beta

`nightly-beta.yml` tags `vYYYY.M.D.N-beta` if main has changes since the newest tag that pass the
[beta gate](#beta-gate). Otherwise it does nothing. The date is the calendar date in `timezone`. A
commit late in the evening gets that day's date even if it's already tomorrow in UTC.

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

| input | default | description |
| --- | --- | --- |
| `timezone` | `America/Chicago` | Time zone for the tag's date |
| `suffix` | `beta` | Prerelease suffix |
| `assert-sequence` | `true` | Run [`version-sequence`](#version-sequence) on the tag before pushing it |
| `prerelease-suffix` | `[A-Za-z0-9]{4}` | Suffix regex for that check |
| `dispatch-release` | `false` | Start your `release.yml` with the new tag |
| `ignore-paths`, `release-types` | same as `beta-gate` | Passed to the gate |
| `ci-workflow` | none | Workflow file (e.g. `ci.yml`) whose push run must pass on the commit first |

The `tag` output is the tag it pushed, or empty if nothing changed.

The release job has to be in your repo, since `./` inside a shared workflow means this repository.
If your `release.yml` only runs on tag pushes, set `dispatch-release: true` and drop the second job.
A tag pushed with `GITHUB_TOKEN` doesn't fire that trigger.

Setting `ci-workflow` runs [`wait-for-ci`](#wait-for-ci), which needs `actions: read` on the calling
job, and raises the job timeout from 5 minutes to 30.

`nightly-beta-scripted.yml` does the same for repos with their own planner script. It runs on
`windows-latest` by default, reads `has_changes` and `next_tag` from the planner, and ANDs that with
the beta gate. It accepts the same gate and `ci-workflow` inputs as `nightly-beta.yml`, plus the
ones below.

| input | default | description |
| --- | --- | --- |
| `runs-on` | `windows-latest` | Runner label |
| `planner` | `./.github/scripts/Get-NightlyBetaPlan.ps1` | Script that picks the next tag and sets `has_changes` and `next_tag` |
| `validate-scripts` | none | Self-test scripts to run before planning, one per line |
| `no-changes-message` | `No app changes since the latest release tag.` | Printed when there is nothing to release |
| `dispatch-release` | `true` | Start your `release.yml` with the new tag |
| `timeout-minutes` | `15` | Job timeout (45 when `ci-workflow` is set) |

### beta-gate

Says whether a commit since the last tag changes the program. Both nightly workflows use it.

```yaml
- uses: actions/checkout@v7
  with:
    fetch-depth: 0

- id: gate
  uses: RealWhyKnot/workflows/beta-gate@v1
  with:
    ignore-paths: |
      app/tests/**
```

| input | default | description |
| --- | --- | --- |
| `base` | nearest tag | Ref to compare against. If it doesn't exist, everything is new and the gate passes. |
| `tag-glob` | `v*` | Tags considered when looking for the nearest one |
| `ignore-paths` | none | Extra globs on top of the built-in list, one per line |
| `release-types` | `feat fix perf refactor revert` | Commit types that count as a release (replaces the list) |

| output | description |
| --- | --- |
| `has_changes` | `true` if some commit has one of those types (or a `!`) and touches a path outside the ignore list |
| `base` | Ref it compared against |

The built-in ignore list is `.github/**`, `.githooks/**`, `docs/**`, `wiki/**`, `tests/**`,
`test/**`, `*.md`, `LICENSE*`, `NOTICE`, `.gitignore`, `.gitattributes`, `.editorconfig` and
`.vscode/**`. A `*` doesn't cross `/`: `*.md` matches Markdown in the repo root but not
`src/help.md`.

Merge commits are skipped, but the commits they merged are checked. A subject that isn't
conventional is judged on its paths alone. The gate passes when no tag is reachable from HEAD, as in
any shallow checkout, and has nothing to check when HEAD is already tagged.

### nightly-plan

Runs the beta gate and works out the day's next nightly tag, without creating or pushing anything.
`nightly-beta.yml` uses it as its planner.

```yaml
- id: plan
  uses: RealWhyKnot/workflows/nightly-plan@v1
  with:
    suffix: beta
```

| input | default | description |
| --- | --- | --- |
| `timezone` | `America/Chicago` | Time zone for the tag's date |
| `suffix` | `beta` | Part after the hyphen. Empty gives a plain `vYYYY.M.D.N`. |
| `tag-glob`, `ignore-paths`, `release-types` | same as `beta-gate` | Passed to the gate |

| output | description |
| --- | --- |
| `has_changes` | `true` if a commit since the nearest tag passes the gate |
| `next_tag` | Tag to create (empty when the gate fails) |

The tag is `vYYYY.M.D.N-suffix`, with `N` one above the highest tag from that day whatever its
suffix, which matches what `version-sequence` expects. Like the gate, you need `fetch-depth: 0` for
it.

### wait-for-ci

Waits for a workflow's push run on a commit and fails unless it passes. I put it in front of
anything that tags or publishes. Needs `actions: read`.

```yaml
- uses: RealWhyKnot/workflows/wait-for-ci@v1
  with:
    workflow: ci.yml
```

| input | default | description |
| --- | --- | --- |
| `sha` | triggering commit | Commit to check |
| `workflow` | `ci.yml` | Workflow file whose runs count |
| `repository` | calling repo | `owner/name` |
| `timeout-minutes` | `20` | How long to wait for a run that's still going |
| `grace-minutes` | `3` | Minutes to wait for a run on a commit by a person before checking its ancestors |
| `max-depth` | `30` | Max ancestors to look through |

| output | description |
| --- | --- |
| `sha` | Commit whose run passed |
| `run-url` | Link to that run |

Only the latest attempt of each run counts. Pull request runs are ignored.

Commits from a push that only touched ignored paths don't get their own run, and neither do commits
pushed with `GITHUB_TOKEN`, like the changelog bot's. For those it walks back along first-parent
history to the nearest commit that has one. A commit by a person gets `grace-minutes` first in case
its run hasn't started yet, and a bot's commit doesn't.

## Repo checks

### commit-subjects

The check from `commit-msg-check.yml` as a step for a job you already have. Same inputs, plus
`range` to override the range it works out from the event. You need a checkout with
`fetch-depth: 0`.

```yaml
- uses: RealWhyKnot/workflows/commit-subjects@v1
  with:
    check-conventional: true
```

### workflow-syntax

Parses the tracked `.ps1`, `.psm1` and `.psd1` files, plus inline `pwsh` blocks under
`.github/workflows`, and fails with a list of the syntax errors. It also fails a block that hides a
native command's error with `2>$null` without resetting `$global:LASTEXITCODE`, and a workflow that
runs `git push` without checking out with `persist-credentials: false`. Use `root` to scan somewhere
other than the workspace.

```yaml
- uses: actions/checkout@v7
- uses: RealWhyKnot/workflows/workflow-syntax@v1
```

Only blocks whose step sets `shell: pwsh` before `run: |` get checked. A step that inherits
`defaults.run.shell` or puts `shell` after `run` is skipped, and so are composite `action.yml`
files. `${{ }}` expressions inside a block aren't flagged.

### conformance

Checks your repo against the shared setup. It fails when

- a `RealWhyKnot/workflows` reference isn't on `shared-ref`
- `.githooks/commit-msg` or `prepare-commit-msg` differs from the copy in [`hooks/`](#hooks),
  ignoring line endings. A hook the repo doesn't have is skipped.
- no workflow calls `commit-msg-check.yml`, or a fork calls it without `forbidden-body-pattern`
- `.github/dependabot.yml` is missing, has no entry for an ecosystem you use, or has an entry
  without a `commit-message` prefix

```yaml
- uses: RealWhyKnot/workflows/conformance@v1
```

| input | default | description |
| --- | --- | --- |
| `shared-ref` | `v1` | Ref that shared references must use |
| `pins` | `warn` | `warn`, `fail` or `off` for stale third-party pins |
| `ignore-ecosystems` | none | Ecosystems the repo leaves out on purpose, one per line |
| `root` | workspace | Repo to check |

It works out the ecosystems from tracked files.

| file | ecosystem |
| --- | --- |
| `Cargo.toml` | cargo |
| project files, `Directory.Packages.props`, `packages.config` | nuget |
| `package.json`, unless it's a Unity or VPM package | npm |
| `requirements*.txt`, `pyproject.toml`, `Pipfile` | pip |
| `go.mod` | gomod |
| any workflow or `action.yml` | github-actions |

A third-party action pinned to a branch, or to an older major than its latest release, gets a
warning. `pins: fail` makes it an error and `pins: off` skips the lookups. SHA pins and local
actions are not checked.

## Setup

### setup-rust

Installs a toolchain with rustup's minimal profile, makes it the default, and caches the cargo
registry, git checkouts and `target`.

```yaml
- uses: RealWhyKnot/workflows/setup-rust@v1
  with:
    components: rustfmt, clippy
```

| input | default | description |
| --- | --- | --- |
| `toolchain` | from the file, else `stable` | Toolchain to install |
| `components`, `targets` | none | Added to whatever the file lists. Comma or newline separated. |
| `working-directory` | `.` | Where `Cargo.lock` and `target` are, and where the search for `rust-toolchain.toml` starts |
| `cache` | `true` | `false` turns off the cargo cache |
| `cache-key` | `cargo` | Cache key prefix. Use a different one per job if the jobs build different things. |

The `toolchain` output is the toolchain it installed.

With no `toolchain` input it looks for `rust-toolchain.toml` in `working-directory`, then in each
parent up to the repo root, and reads `channel`, `components` and `targets` from it. Without one it
uses `stable`. The cache key is the OS, the toolchain and a hash of `Cargo.lock`.

### setup-nsis

Installs NSIS with Chocolatey and puts it on `PATH`, unless `makensis /VERSION` already reports the
version you asked for. Windows only. `version` is major.minor, default `3.12`.

```yaml
- uses: RealWhyKnot/workflows/setup-nsis@v1
  with:
    version: '3.12'
```

## Repo files

### hooks

`commit-msg` rejects a subject with more than one build stamp, and `prepare-commit-msg` adds the
current one. They're kept here so their default stamp pattern stays identical to the
`commit-subjects` action's, and a test in this repo fails if they differ.

```
pwsh path/to/workflows/hooks/Install-Hooks.ps1 -RepoRoot . -Force
```

This copies both hooks into `.githooks/`, writes a `hook-config` for any non-default setting, and
points `core.hooksPath` at the folder. Without `-Force` it won't overwrite a hook you've edited.

Pass the same settings you gave `commit-msg-check.yml`.

| flag | effect |
| --- | --- |
| `-StampPattern` | Narrow what counts as a build stamp |
| `-NoStamp` | No stamping, and `prepare-commit-msg` isn't installed |
| `-CheckConventional` | Also require conventional subjects |
| `-ConventionalPattern` | Regex for a conventional subject, if not the default |
| `-ForbiddenBodyPattern` | Reject a message matching this |
| `-VersionFile` | File holding the build stamp. Default: `version.txt`. |
| `-VersionInGitDir` | Keep that file inside `.git` so stamping doesn't leave the worktree dirty |

Merge, revert, `fixup!` and `squash!` subjects skip the conventional and body checks.

There is no shared `pre-push`. Each repo keeps its own for its linter.

### lint

`lint/<lang>/` has my baseline formatter and linter configs, one folder per language. Install-Lint
copies them into a repo.

```
pwsh path/to/workflows/lint/Install-Lint.ps1 -RepoRoot .
```

Without `-Lang` it picks languages from your repo's tracked files, skipping vendored code. HTML
files count as CSS, and Svelte, Vue and Astro files count as both TypeScript and CSS. Pass
`-Lang rust,csharp` to pick them yourself. Each file goes to the same relative path in your repo. If
a file is already there and differs, it's left alone unless you pass `-Force`.

`lint/common/` is installed in all repos. `vendored-paths.txt` lists folders that keep their
upstream style, and the shared copy only has generic names like `vendor/`. `name/` matches a folder
with that name at any depth and `/path/` matches from the repo root. You list your repo's own
upstream folders in a `vendored-paths.local.txt` at its root, same format. Install-Lint adds those
to the excludes in the ruff, pyright, ESLint, Stylelint, Prettier and `.editorconfig` configs it
installs and in its copy of `vendored-paths.txt`, and treats the result as current on the next run.

`style_check.py` and the `style_*.py` modules beside it check things the linters can't: comments and
inline suppressions in Rust, C# and Python; source files over 600 lines; Sass, Less and Stylus
files; committed generated C#; crates that don't inherit `[workspace.lints]`; lint or format configs
below the repo root or inside project files. Run it from the repo root with Python 3.11+. `-B`
keeps `__pycache__` out of the repo.

```
python -B style_check.py
```

It also fails if `vendored-paths.local.txt` has an entry the installed `vendored-paths.txt` lacks,
because the other configs won't have it either until Install-Lint runs again. Exit code 1 means it
found something and 2 means it couldn't run, for example because a local entry is badly formatted.

Files directly under `lint/<lang>/merge/` go inside a file your repo already has, like the
`[workspace.lints]` table in `Cargo.toml`, and Install-Lint lists any line or key that file is
missing. If the file is missing it's only a note, unless the language's `install.psd1` names it in a
`Merge` entry.

The TypeScript and CSS tools are pinned to exact versions in `lint/typescript/merge/package.json`
and `lint/css/merge/package.json`, and Dependabot checks those pins weekly. Install-Lint lists the
pins where your `package.json` differs. After a bump, run it again in each repo to see what's left to
update there.

An `install.psd1` in a language folder adjusts what a given repo gets. A rule can swap in one of the
variants kept in folders under `merge/`, the way Unity repos get `merge/unity/.editorconfig`. It can
also skip a file if it gives a reason, which is how Unity repos go without the root
`Directory.Build.props`. A rule that does neither is a leftover per-repo tweak, and the script tells
you to remove it.

When two languages both have `.editorconfig`, their sections are merged into one file. Any other
file two languages both have is copied once if the copies match, like the Prettier config in
TypeScript and CSS. If they set a key differently, or their copies of a file differ, you sort that
out by hand. The script lists anything like that and exits 1, and otherwise exits 0.

### Dependabot

All my repos have a `.github/dependabot.yml`, and `conformance` checks that it covers each ecosystem
the repo uses. I start new ones from this.

```yaml
version: 2
updates:
  - package-ecosystem: github-actions
    directory: /
    commit-message:
      prefix: chore
      include: scope
    schedule:
      interval: weekly
    open-pull-requests-limit: 3
    groups:
      actions:
        update-types: [minor, patch]
  - package-ecosystem: cargo
    directory: /
    commit-message:
      prefix: chore
      include: scope
    schedule:
      interval: weekly
    open-pull-requests-limit: 5
    groups:
      cargo:
        update-types: [minor, patch]
```

Swap the second entry for whatever you build with. `chore` passes the conventional subject check but
isn't one of the beta gate's release types. A dependency bump on its own doesn't tag a nightly.
`conformance` only checks coverage and the prefix. Schedules and limits are up to each repo.

## Versioning

Releases are tagged by date, `vYYYY.M.D.N`, like my other repos. `N` is 0 for the first release of
the day and goes up by one for each one after. Every release gets a GitHub release listing its
changes, and `v1` moves to the newest. Tags up to `v1.6.2` are semantic versions and still work.

Inside a release the shared workflows call the actions at that same tag. For example,
`nightly-beta.yml@v2026.10.28.0` runs `nightly-plan@v2026.10.28.0`. Pinning or rolling back a
workflow does the same to the actions it calls. On `main` they call `@v1`.

Any change outside docs, tests and this repo's own CI gets a release. A breaking change would get a
new moving tag, `v2`, and `v1` would stay put.

To pin a repo, use a release tag like `@v2026.10.28.0` and set `shared-ref` on `conformance` to the
same tag, or it will flag the pin.

After a push to `main` I run `.github/scripts/New-Release.ps1`. It waits for CI to pass on the
commit, checks that something besides docs, tests or CI changed since the last release, tags the
day's next number and moves `v1`. `-PlanOnly` prints the tag without creating anything. The tag push
runs `release.yml`, which checks the tag's sequence, writes the notes with `release-notes` and
publishes.

CI runs the `Test-*.ps1` scripts on ubuntu and windows, plus actionlint, `workflow-syntax` and
`conformance` on this repo. `commits.yml` runs `commit-msg-check.yml` on this repo's own pushes and
PRs, with stamps off and conventional subjects required. It is not meant for other repos.
