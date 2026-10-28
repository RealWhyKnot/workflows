# workflows

[![CI](https://github.com/RealWhyKnot/workflows/actions/workflows/ci.yml/badge.svg)](https://github.com/RealWhyKnot/workflows/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/RealWhyKnot/workflows)](https://github.com/RealWhyKnot/workflows/releases)

The GitHub Actions, reusable workflows, git hooks and lint configs that my repos share.

## Picking a version

| ref | points to |
| --- | --- |
| `@v1` | latest release (moves with every release; all my repos use it) |
| `@v2026.10.28.0` | release 2026.10.28.0, which never moves. Change the tag to upgrade or roll back. |
| `@<commit sha>` | that commit |

If you use these from your own repo, pin a release tag (see [Versioning](#versioning)). Each release
on the [releases page](https://github.com/RealWhyKnot/workflows/releases) lists what changed.

## Contents

| workflow | what it does |
| --- | --- |
| [`commit-msg-check.yml`](#commit-msg-checkyml) | Checks commit subjects for build stamps, and optionally for conventional types and forbidden body text |
| [`version-guard.yml`](#version-guardyml) | Fails if a `const string Version` comes back in `Editor/` or `Runtime/` |
| [`dependabot-automerge.yml`](#dependabot-automergeyml) | Auto-merge for the Dependabot updates you allow |
| [`repo-checks.yml`](#repo-checksyml) | `workflow-syntax`, `conformance` and actionlint |
| [`changelog-append.yml`](#changelog-append) | Runs your changelog script over a push and commits the result, signed |
| [`nightly-beta.yml`](#nightly-beta) | Tags a nightly beta when main has changes that ship |
| [`nightly-beta-scripted.yml`](#nightly-beta) | Same, but your own script picks the tag |

| group | actions |
| --- | --- |
| Releases | [`resolve-tag`](#resolve-tag), [`version-sequence`](#version-sequence), [`release-notes`](#release-notes), [`checksums`](#checksums), [`publish-release`](#publish-release), [`commit-on-branch`](#commit-on-branch) |
| Nightly betas | [`beta-gate`](#beta-gate), [`nightly-plan`](#nightly-plan), [`wait-for-ci`](#wait-for-ci) |
| Repo checks | [`commit-subjects`](#commit-subjects), [`workflow-syntax`](#workflow-syntax), [`conformance`](#conformance) |
| Setup | [`setup-rust`](#setup-rust), [`setup-nsis`](#setup-nsis) |

There's also the [git hooks](#hooks), the [lint baselines](#lint) and a starting
[Dependabot config](#dependabot).

## Reusable workflows

Each one sets its own runner and timeout, and the calling job is only a `uses:` line.

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

Runs that Dependabot triggers get a read-only token. If the calling job doesn't list the permissions
above, the merge call fails.

### commit-msg-check.yml

Fails when a commit subject has more than one CalVer build stamp. It can also require conventional
subjects, and reject commit bodies that match a pattern. Every input is optional.

| input | default | description |
| --- | --- | --- |
| `check-stamp` | `true` | Fail on a subject with more than one build stamp |
| `stamp-pattern` | `\([0-9]{4}\.[0-9]+\.[0-9]+\.[0-9]+(-([A-Fa-f0-9]{4}\|beta))?\)` | Regex for one stamp |
| `check-conventional` | `false` | Also require conventional subjects |
| `conventional-pattern` | `^(feat\|fix\|chore\|ci\|docs\|refactor\|revert\|test\|perf\|diag\|style)(\([a-z0-9-]+\))?!?: .+` | Regex for a conventional subject |
| `forbidden-body-pattern` | none | Fail any non-merge commit whose body matches. I use it in forks to keep upstream issue numbers out of the history. |

Merge and revert commits skip the conventional and body checks (a merge subject is never
conventional), but their stamps are still counted.

### version-guard.yml

Fails if a `const string Version` comes back in `Editor/` or `Runtime/`. It has one input,
`error-hint`, a sentence appended to the failure message. It defaults to
`Use PackageInfo.FindForAssembly() instead.`

### dependabot-automerge.yml

Turns on auto-merge for Dependabot PRs whose update type you allow.

| input | default | description |
| --- | --- | --- |
| `update-types` | `version-update:semver-patch` | Update types allowed to auto-merge, one per line |
| `merge-method` | `rebase` | `merge`, `squash` or `rebase` |

### repo-checks.yml

Runs [`workflow-syntax`](#workflow-syntax), [`conformance`](#conformance) and actionlint (with
shellcheck). I call it from CI in every repo to catch drift.

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

With no `tag` it uses the ref that triggered the run, so the same step works for a tag push and for
a manual re-release.

| input | default | description |
| --- | --- | --- |
| `tag` | triggering ref | Tag to release |
| `tag-pattern` | `^v\d{4}\.\d+\.\d+\.\d+(-([A-Fa-f0-9]{4}\|beta))?$` | Regex for a valid tag |
| `prerelease-pattern` | `-beta` only | Regex for prerelease tags. Widen it if every suffix should count. |
| `require-tag-exists` | `true` | Fail unless the tag resolves to a commit in the checkout |

| output | description |
| --- | --- |
| `tag` | The tag |
| `version` | The tag minus its leading `v` |
| `prerelease` | `true` if the tag matches `prerelease-pattern` |
| `channel` | `beta` for a prerelease, else `release` |
| `sha` | Commit the tag points at (empty when `require-tag-exists` is off) |

There are two patterns because a tag like `-A1B2` is valid without being a beta, and my repos don't
all agree on how to treat it.

### version-sequence

Fails unless a CalVer tag uses the next free revision for its day.

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
whatever its suffix. The tag under test is left out of the count, so re-running a release for an
existing tag still passes. You need `fetch-depth: 0` on the checkout or the earlier tags aren't
there.

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

The one output, `file`, is the path of the Markdown it wrote. Check out with `fetch-depth: 0` and
`fetch-tags: true`, or there's no history to read.

Commits are grouped by prefix into Breaking Changes, Features, Bug Fixes, Performance, Changes,
Documentation, Build, CI, Tests, Chores and Other, with any `type!:` subject under Breaking Changes.
Merge commits and anything marked `[skip changelog]` are dropped, and a CalVer stamp at the end of a
subject (e.g. `(2026.9.7.1-A528)`) is stripped off.

Authors are credited with a link to their GitHub profile, which doesn't notify them. A bare
`@handle` would ping the person and add them to the release's Contributors avatars, and that's wrong
in a fork whose notes include upstream commits the author never sent to my repo. Bots like
`dependabot[bot]` are written as plain text, since their login isn't a profile path.

The commits API maps each commit to its author's GitHub login, outside contributors included. When
the API can't be reached it falls back to `git log` and the raw author name. On a first release
every commit up to the tag is listed. The API call needs `GH_TOKEN`, which the action sets to
`github.token` for you.

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
| `archives` | required | Paths or globs, one per line. A pattern that matches nothing is an error (a renamed artifact fails the job instead of publishing a table with a row missing). |
| `contents` | sibling | Directory whose files are listed in the manifest after the archive's own row. If unset, each archive uses the directory beside it with the same base name (where a publish-then-compress job leaves its files). |
| `manifest-suffix` | `.integrity.tsv` | Suffix for the file written next to each archive |
| `manifest` | `true` | `false` returns the table without writing any manifests |
| `units` | `MiB` | `MiB` (1048576 bytes) or `MB` (1000000). The table header says which. |
| `table-file` | none | Also write the table to this path |

| output | description |
| --- | --- |
| `sha256` | SHA-256 of the first archive |
| `manifests` | Paths of the manifests written, one per line |
| `table` | The Markdown table |

A manifest is tab-separated, no header, lowercase hashes, one `hash  bytes  name` line per file with
the archive first. `.tar.gz` drops both extensions (`app-1.0.0.tar.gz` gets
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
| `assets` | none | Files to upload, one per line. Entries containing `*` or `?` are expanded (e.g. `dist/python/*`), and a glob with no match is skipped. |
| `repository` | calling repo | `owner/name` to publish to |
| `target` | none | Commit-ish for the release |
| `prerelease` | `false` | Adds `--prerelease --latest=false` |
| `draft-first` | `false` | Create a draft, check every asset is attached, then publish |
| `delete-existing` | `false` | Delete any existing release for the tag first |
| `verify-asset` | none | Asset whose digest is checked after upload |
| `verify-sha256` | none | Expected SHA-256 of that asset |

Turn on `draft-first` anywhere a failed upload would otherwise leave an empty release published. If
a re-run finds a draft for the tag (one a failed run left behind, say), it checks that draft's
assets and publishes it the same way.

With both `verify-asset` and `verify-sha256` set, it polls the API until the uploaded asset's digest
matches (an upload can report success before the asset is readable).

Cleaning up a half-made release is left to your workflow, in a step that runs on failure.

```yaml
- name: Remove a partial release
  if: failure()
  run: gh release delete ${{ steps.tag.outputs.tag }} --yes 2>$null; $global:LASTEXITCODE = 0
  shell: pwsh
```

### commit-on-branch

Commits files to a branch with the GraphQL `createCommitOnBranch` mutation. GitHub signs those
commits, so they pass a required-signatures rule that a plain `git push` from Actions would fail.

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
| `warn-on-failure` | `false` | Warn instead of failing the job (e.g. when a missed changelog commit shouldn't fail a release) |

It reads the branch head and sends it as `expectedHeadOid`. GitHub rejects the mutation if another
commit landed on the branch in between.

Commits made with `GITHUB_TOKEN` don't trigger workflows, so the changelog commit doesn't re-run the
job that made it.

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

Keep the `if:` guard on your job. A `GITHUB_TOKEN` commit won't trigger workflows, but a manual
re-run or a different actor still can loop.

## Nightly betas

### nightly-beta

`nightly-beta.yml` tags `vYYYY.M.D.N-beta` if main has changes since the newest tag that pass the
[beta gate](#beta-gate). Otherwise it does nothing. The date is the calendar date in `timezone`, so
a commit late in the evening gets that day's date even if it's already tomorrow in UTC.

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

It outputs `tag`, the tag it pushed, or an empty string if nothing changed.

The release job has to live in your repo, since `./` inside a shared workflow means this repository.
If your `release.yml` only runs on tag pushes, set `dispatch-release: true` and drop the second job
(a tag pushed with `GITHUB_TOKEN` never fires that trigger).

Setting `ci-workflow` runs [`wait-for-ci`](#wait-for-ci), which needs `actions: read` on the calling
job, and raises the job timeout from 5 minutes to 30.

`nightly-beta-scripted.yml` does the same for repos with their own planner script. It runs on
`windows-latest` by default, reads `has_changes` and `next_tag` from the planner, and ANDs that with
the beta gate. It takes the gate and `ci-workflow` inputs from `nightly-beta.yml` and these.

| input | default | description |
| --- | --- | --- |
| `runs-on` | `windows-latest` | Runner label |
| `planner` | `./.github/scripts/Get-NightlyBetaPlan.ps1` | Script that picks the next tag and sets `has_changes` and `next_tag` |
| `validate-scripts` | none | Self-test scripts to run before planning, one per line |
| `no-changes-message` | `No app changes since the latest release tag.` | Printed when there's nothing to release |
| `dispatch-release` | `true` | Start your `release.yml` with the new tag |
| `timeout-minutes` | `15` | Job timeout (45 when `ci-workflow` is set) |

### beta-gate

Says whether any commit since the last tag changes the program. Both nightly workflows use it.

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
| `release-types` | `feat fix perf refactor revert` | Commit types that ship (replaces the list) |

| output | description |
| --- | --- |
| `has_changes` | `true` if some commit has a type that ships (or a `!`) and touches a path outside the ignore list |
| `base` | Ref it compared against |

The built-in ignore list is `.github/**`, `.githooks/**`, `docs/**`, `wiki/**`, `tests/**`,
`test/**`, `*.md`, `LICENSE*`, `NOTICE`, `.gitignore`, `.gitattributes`, `.editorconfig` and
`.vscode/**`. A `*` doesn't cross `/`: `*.md` matches Markdown in the repo root but not
`src/help.md`.

Merge commits are skipped but the commits they bring in are checked, and a subject that isn't
conventional is judged on its paths alone. If no tag is reachable from HEAD the gate passes, and if
HEAD is already tagged there's nothing to check. A shallow checkout has no tags and always passes.

### nightly-plan

Runs the beta gate, then works out the next nightly tag for the day. It's the planner inside
`nightly-beta.yml`. It doesn't create or push anything.

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
suffix, which matches what `version-sequence` expects. It needs `fetch-depth: 0`, like the gate.

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
| `grace-minutes` | `3` | How long a person's commit with no run waits before ancestors are checked |
| `max-depth` | `30` | Max ancestors to look through |

| output | description |
| --- | --- |
| `sha` | Commit whose run passed |
| `run-url` | Link to that run |

Only the latest attempt of each run counts. Pull request runs are ignored.

Some commits never get their own run: a push that only touched ignored paths, or a commit pushed
with `GITHUB_TOKEN` such as the changelog bot's. For those it walks back along first-parent history
to the nearest commit that has one. Commits by a person wait `grace-minutes` first in case the run
hasn't started yet. Bot commits don't wait.

## Repo checks

### commit-subjects

The check from `commit-msg-check.yml` as a step for a job you already have. Same inputs, plus
`range` to override the range it works out from the event. Needs a checkout with `fetch-depth: 0`.

```yaml
- uses: RealWhyKnot/workflows/commit-subjects@v1
  with:
    check-conventional: true
```

### workflow-syntax

Parses every tracked `.ps1`, `.psm1` and `.psd1` file, plus every inline `pwsh` block under
`.github/workflows`, and fails with a list of the syntax errors. It also fails a block that hides a
native command's error with `2>$null` without resetting `$global:LASTEXITCODE`, and a workflow that
runs `git push` without checking out with `persist-credentials: false`. Use `root` to scan somewhere
other than the workspace.

```yaml
- uses: actions/checkout@v7
- uses: RealWhyKnot/workflows/workflow-syntax@v1
```

`${{ }}` expressions in a block aren't flagged. Only blocks whose step sets `shell: pwsh` before
`run: |` get checked; steps that inherit `defaults.run.shell` or put `shell` after `run` are
skipped, and so are composite `action.yml` files.

### conformance

Fails if a `RealWhyKnot/workflows` reference isn't on `shared-ref`, if `.githooks/commit-msg` or
`prepare-commit-msg` differs from the copy in [`hooks/`](#hooks) (line endings are ignored, and a
hook the repo doesn't have is skipped), if no workflow calls `commit-msg-check.yml` or a fork calls
it without `forbidden-body-pattern`, or if `.github/dependabot.yml` is missing, has no entry for an
ecosystem the repo uses, or has an entry without a `commit-message` prefix.

```yaml
- uses: RealWhyKnot/workflows/conformance@v1
```

| input | default | description |
| --- | --- | --- |
| `shared-ref` | `v1` | Ref every shared reference must use |
| `pins` | `warn` | `warn`, `fail` or `off` for stale third-party pins |
| `ignore-ecosystems` | none | Ecosystems the repo leaves out on purpose, one per line |
| `root` | workspace | Repo to check |

It works out the ecosystems from tracked files. `Cargo.toml` means cargo, project files,
`Directory.Packages.props` and `packages.config` mean nuget, `package.json` means npm (unless it's a
Unity or VPM package), `requirements*.txt`, `pyproject.toml` and `Pipfile` mean pip, `go.mod` means
gomod, and any workflow or `action.yml` means github-actions.

Third-party actions pinned to a branch, or to an older major than their latest release, get a
warning. `pins: fail` makes it an error and `pins: off` skips the lookups. SHA pins and local
actions aren't checked.

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

It outputs `toolchain`, the toolchain it installed.

With no `toolchain` input it reads `channel`, `components` and `targets` from `rust-toolchain.toml`
(in `working-directory`, then each parent up to the repo root) and falls back to `stable`. A version
pinned there doesn't need repeating in the workflow. The cache key is the OS, the toolchain and a
hash of `Cargo.lock`.

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
`commit-subjects` action's, and a test in this repo fails if the two drift.

```
pwsh path/to/workflows/hooks/Install-Hooks.ps1 -RepoRoot . -Force
```

This copies both hooks into `.githooks/`, writes a `hook-config` for any non-default setting, and
points `core.hooksPath` at the folder. Without `-Force` it won't overwrite a hook you've edited.

Pass the same settings you gave `commit-msg-check.yml`. They're saved in `hook-config`.

| flag | effect |
| --- | --- |
| `-StampPattern` | Narrow what counts as a build stamp |
| `-NoStamp` | No stamping, and `prepare-commit-msg` isn't installed |
| `-CheckConventional` | Also require conventional subjects |
| `-ConventionalPattern` | Regex for a conventional subject, if not the default |
| `-ForbiddenBodyPattern` | Reject a message matching this (I use it to keep upstream issue numbers out of forks) |
| `-VersionFile` | File holding the build stamp. Default `version.txt`. |
| `-VersionInGitDir` | Keep that file inside `.git` so stamping never dirties the worktree |

Merge, revert, `fixup!` and `squash!` subjects skip the conventional and body checks.

There's no shared `pre-push`. Each repo runs its own linter from it.

### lint

`lint/<lang>/` has my baseline formatter and linter configs, one folder per language. Install-Lint
copies them into a repo.

```
pwsh path/to/workflows/lint/Install-Lint.ps1 -RepoRoot .
```

Without `-Lang` it picks languages from the repo's tracked files, skipping vendored code. Pass
`-Lang rust,csharp` to pick them yourself. Each file lands at the same relative path in the repo. If
a file is already there and differs, it's left alone unless you pass `-Force`.

Everything in `lint/common/` goes into every repo. `vendored-paths.txt` lists code that keeps its
upstream style (`name/` matches a folder with that name at any depth, `/path/` matches from the repo
root) and only has generic names like `vendor/`. A repo lists its own upstream folders in a
`vendored-paths.local.txt` at its root, same format. Install-Lint adds those to the excludes in the
files it installs (ruff, pyright, ESLint, Prettier, `.editorconfig`, and its copy of
`vendored-paths.txt`) and treats the result as current on the next run.

`style_check.py` and the `style_*.py` modules beside it check things the linters can't: comments and
inline suppressions in Rust, C# and Python; source files over 600 lines; committed generated C#;
crates that don't inherit `[workspace.lints]`; lint or format configs below the repo root or inside
project files. Run it from the repo root with Python 3.11+, with `-B` so it doesn't leave a
`__pycache__` behind.

```
python -B style_check.py
```

It also fails if `vendored-paths.local.txt` has an entry the installed `vendored-paths.txt` lacks,
because the other configs won't have it either until Install-Lint runs again. Exit code 1 means it
found something, 2 means it couldn't run (a badly formatted local entry is one way to get a 2).

Files directly under `lint/<lang>/merge/` go inside a file the repo already has, like the
`[workspace.lints]` table in `Cargo.toml`. Install-Lint checks that file for every line or key and
lists what's missing. A missing target file is only a note unless the language's `install.psd1`
names it in a `Merge` entry. Folders under `merge/` hold variants, used only when a rule picks one.

The TypeScript tools are pinned to exact versions in `lint/typescript/merge/package.json`, and
Dependabot checks those pins weekly. Install-Lint lists every pin where a repo's `package.json`
differs. After a bump, run it again in each repo to see what's left to update there.

An `install.psd1` in a language folder adjusts what a given repo gets. A rule can swap in another
file (Unity repos get `merge/unity/.editorconfig`) or skip one with a reason (Unity repos don't get
the root `Directory.Build.props`). A rule that does neither is a leftover per-repo tweak, and the
script tells you to remove it. When two languages both ship `.editorconfig`, their sections are
merged into one file and any key they set differently is yours to settle. Any other file both ship
is left to you as well. If there's anything to do by hand the script lists it and exits 1, otherwise
0.

### Dependabot

Every repo has a `.github/dependabot.yml`, and `conformance` checks it covers everything the repo
uses. I start new ones from this.

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

Swap the second entry for whatever the repo builds with. `chore` passes the conventional subject
check and isn't a type the beta gate ships, so a dependency bump alone never tags a nightly.
Schedules and limits can vary per repo (the check only looks at coverage and the prefix).

## Versioning

Releases are tagged by date, `vYYYY.M.D.N`, like my other repos. `N` is 0 for the first release of
the day and goes up by one for each one after. Every release gets a GitHub release listing its
changes, and `v1` moves to the newest. Tags up to `v1.6.2` are semantic versions and still work.

Inside a release the shared workflows call the actions at that same tag. For example,
`nightly-beta.yml@v2026.10.28.0` runs `nightly-plan@v2026.10.28.0`. Pinning or rolling back a
workflow pins or rolls back every action it calls. On `main` they call `@v1`.

Any change to shipped code gets a release; changes to docs, tests or this repo's own CI don't. A
breaking change would get a new moving tag, `v2`, and `v1` would stay put.

To pin a repo, use a release tag like `@v2026.10.28.0` and set `shared-ref` on `conformance` to the
same tag, or it'll flag the pin.

After a push to `main` I run `.github/scripts/New-Release.ps1`. It waits for CI to pass on the
commit, checks whether anything shipped since the last release, tags the day's next number and moves
`v1`. `-PlanOnly` prints the tag without creating anything. The tag push runs `release.yml`, which
checks the tag's sequence, writes the notes with `release-notes` and publishes.

CI runs every `Test-*.ps1` in the repo on ubuntu and windows, plus actionlint, `workflow-syntax` and
`conformance` on this repo. `commits.yml` runs `commit-msg-check.yml` on this repo's own pushes and
PRs, with stamps off and conventional subjects required (it isn't meant for other repos to call).
