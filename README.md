# workflows

[![CI](https://github.com/RealWhyKnot/workflows/actions/workflows/ci.yml/badge.svg)](https://github.com/RealWhyKnot/workflows/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/RealWhyKnot/workflows)](https://github.com/RealWhyKnot/workflows/releases)

Shared GitHub Actions I use across my own repos, so a fix goes in once here and every repo picks it
up.

## Picking a version

| ref | what you get |
| --- | --- |
| `@v1` | The newest release. It moves every time I release, and all my repos use it. |
| `@v2026.10.28.0` | That release and nothing newer. Change the tag to upgrade or roll back. |
| `@<commit sha>` | The same, held by a commit instead of a tag. |

If you're using these from your own repo, pin a release tag. [Versioning](#versioning) has the
details, and the [releases page](https://github.com/RealWhyKnot/workflows/releases) lists what
changed in each one.

## Contents

Reusable workflows replace a whole job:

| workflow | what it does |
| --- | --- |
| [`commit-msg-check.yml`](#commit-msg-checkyml) | Checks commit subjects for build stamps, and optionally for conventional types and forbidden body text. |
| [`version-guard.yml`](#version-guardyml) | Fails if a `const string Version` shows up again in `Editor/` or `Runtime/`. |
| [`dependabot-automerge.yml`](#dependabot-automergeyml) | Turns on auto-merge for the Dependabot updates you allow. |
| [`repo-checks.yml`](#repo-checksyml) | Runs `workflow-syntax`, `conformance` and actionlint. |
| [`changelog-append.yml`](#changelog-append) | Runs your changelog script over a push and commits the result, signed. |
| [`nightly-beta.yml`](#nightly-beta) | Tags a nightly beta when main has changes that ship. |
| [`nightly-beta-scripted.yml`](#nightly-beta) | The same, with your own script picking the tag. |

Actions are steps inside a job you already have:

| group | actions |
| --- | --- |
| Releases | [`resolve-tag`](#resolve-tag), [`version-sequence`](#version-sequence), [`release-notes`](#release-notes), [`checksums`](#checksums), [`publish-release`](#publish-release), [`commit-on-branch`](#commit-on-branch) |
| Nightly betas | [`beta-gate`](#beta-gate), [`nightly-plan`](#nightly-plan), [`wait-for-ci`](#wait-for-ci) |
| Repo checks | [`commit-subjects`](#commit-subjects), [`workflow-syntax`](#workflow-syntax), [`conformance`](#conformance) |
| Setup | [`setup-rust`](#setup-rust), [`setup-nsis`](#setup-nsis) |

The repo also holds the [git hooks](#hooks), the [lint baselines](#lint) and the
[Dependabot layout](#dependabot) my repos share.

## Reusable workflows

Calling one brings the runner, timeout and checkout with it:

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

Grant `permissions` on the job that calls the workflow. A called workflow can keep or drop what the
caller granted but can't add to it, and a missing permission shows up as a 403 deep inside the run.
Each workflow needs:

| workflow | permissions |
| --- | --- |
| `commit-msg-check.yml`, `version-guard.yml`, `repo-checks.yml` | `contents: read` |
| `dependabot-automerge.yml` | `contents: write`, `pull-requests: write` |
| `changelog-append.yml` | `contents: write` |
| `nightly-beta.yml` | `contents: write`, plus `actions: read` with `ci-workflow` |
| `nightly-beta-scripted.yml` | `contents: write`, `actions: write` |

Workflows that Dependabot triggers get a read-only token, so the calling job has to list these
permissions or the merge call fails.

### commit-msg-check.yml

Fails on a commit subject with more than one CalVer build stamp. It can also require conventional
subjects and reject commit bodies that match a pattern. Inputs, all optional:

| input | default | what it does |
| --- | --- | --- |
| `check-stamp` | `true` | Count the build stamps in each subject and fail on more than one. |
| `stamp-pattern` | `\([0-9]{4}\.[0-9]+\.[0-9]+\.[0-9]+(-([A-Fa-f0-9]{4}\|beta))?\)` | What a single stamp looks like. |
| `check-conventional` | `false` | Require conventional subjects as well. |
| `conventional-pattern` | `^(feat\|fix\|chore\|ci\|docs\|refactor\|revert\|test\|perf\|diag\|style)(\([a-z0-9-]+\))?!?: .+` | What a conventional subject looks like. |
| `forbidden-body-pattern` | none | Fails a non-merge commit whose body matches it anywhere. I use it to keep upstream issue numbers out of a fork's history. |

Merge and revert subjects skip the conventional and body checks, since a merge subject is never a
conventional commit. They still count toward the stamp check.

### version-guard.yml

Fails if a `const string Version` shows up again in `Editor/` or `Runtime/`. Its one input,
`error-hint`, is a sentence added to the failure message that tells people what to use instead. It
defaults to `Use PackageInfo.FindForAssembly() instead.`

### dependabot-automerge.yml

Turns on auto-merge for Dependabot pull requests of the update types you allow.

| input | default | what it does |
| --- | --- | --- |
| `update-types` | `version-update:semver-patch` | Update types that may auto-merge, one per line. |
| `merge-method` | `rebase` | `merge`, `squash` or `rebase`. |

### repo-checks.yml

Runs [`workflow-syntax`](#workflow-syntax), [`conformance`](#conformance), and actionlint with
shellcheck. I call it from every repo's CI, so drift fails the build.

| input | default | what it does |
| --- | --- | --- |
| `pins` | `warn` | Passed on to `conformance`. |
| `ignore-ecosystems` | none | Passed on to `conformance`. |
| `actionlint` | `true` | Run actionlint and shellcheck over the workflows. |

## Releases

### resolve-tag

Checks the tag being released and tells you about it.

```yaml
- id: tag
  uses: RealWhyKnot/workflows/resolve-tag@v1
  with:
    tag: ${{ inputs.tag }}
```

Without a `tag` it uses the ref that triggered the run, so the same step handles a tag push and a
manual re-release.

| input | default | what it does |
| --- | --- | --- |
| `tag` | the triggering ref | Tag to release. |
| `tag-pattern` | `^v\d{4}\.\d+\.\d+\.\d+(-([A-Fa-f0-9]{4}\|beta))?$` | What a valid tag looks like. |
| `prerelease-pattern` | `-beta` only | Which tags are prereleases. Widen it if every suffix should be one. |
| `require-tag-exists` | `true` | Fail unless the tag resolves to a commit in the checkout. |

| output | value |
| --- | --- |
| `tag` | The tag. |
| `version` | The tag without its `v`. |
| `prerelease` | `true` when the tag matches `prerelease-pattern`. |
| `channel` | `beta` for a prerelease, otherwise `release`. |
| `sha` | The commit the tag points at. Empty when `require-tag-exists` is off. |

The two patterns are separate because a `-A1B2` tag is valid but isn't a beta, and some of my repos
want it treated one way and some the other.

### version-sequence

Fails unless a CalVer tag takes the next free revision for its day.

```yaml
- uses: RealWhyKnot/workflows/version-sequence@v1
  with:
    tag: ${{ steps.tag.outputs.tag }}
```

| input | default | what it does |
| --- | --- | --- |
| `tag` | required | The tag being released. |
| `prerelease-suffix` | `[A-Za-z0-9]{4}` | A regex for what comes after the hyphen. It only decides whether the tag itself is valid. |
| `repo-root` | the workspace | Repository to read the tags from. |

Each day starts at `.0`, and every tag after that is one above the highest tag from the same day,
whatever its suffix. The tag being checked doesn't count, so re-running the release for a tag that
already exists still passes. Check out with `fetch-depth: 0`, or the earlier tags won't be there to
count.

The default suffix accepts `-beta` and `-A1B2` but not `-rc.1`. In repos that use any suffix I pass
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

| input | default | what it does |
| --- | --- | --- |
| `tag` | required | The tag you're releasing. |
| `repository` | the calling repo | `owner/name` to read commits from. |
| `previous-tag` | worked out | What to diff against. A stable tag is compared with the last stable tag, and a prerelease with whatever tag came before it. |
| `title` | none | An H1 above the changes. |
| `extra` | none | Markdown added after the changelog, for downloads and hashes. |

Its one output is `file`, the path to the Markdown it wrote. The checkout needs `fetch-depth: 0` and
`fetch-tags: true`, or there's no history to read.

Commits are grouped by their conventional prefix into Breaking Changes, Features, Bug Fixes,
Performance, Changes, Documentation, Build, CI, Tests, Chores and Other, and a `type!:` subject goes
under Breaking Changes. Merge commits and anything marked `[skip changelog]` are left out. A CalVer
build stamp at the end of a subject, like `(2026.9.7.1-A528)`, is stripped.

Commit authors get a link to their profile instead of a bare `@handle`. GitHub treats a bare handle
as a mention: it pings the person and adds them to the release's Contributors avatars, which is
wrong when a fork's notes cover commits their upstream author never sent to my repo. A link looks
the same and pings nobody. Bots such as `dependabot[bot]` are named in plain text, since their login
isn't a profile path.

Authors are looked up through the commits API, which gets outside contributors' GitHub logins
right. When the API can't be reached it falls back to `git log` and the raw author name. A first
release lists every commit up to the tag. The API call needs `GH_TOKEN`, and the action passes it
`github.token` for you.

### checksums

Hashes release archives, writes an integrity manifest next to each one, and returns a Markdown table
you can put in the release notes.

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

| input | default | what it does |
| --- | --- | --- |
| `archives` | required | Paths or globs, one per line. A pattern that matches no file is an error, so a renamed artifact fails the job before a table with a missing row gets published. |
| `contents` | sibling | A directory whose files are listed after each archive's row, so the manifest also covers what's inside the archive. When it's unset, each archive picks up the directory next to it with the same base name, which is what a job that publishes and then compresses already leaves behind. |
| `manifest-suffix` | `.integrity.tsv` | Suffix of the file written next to each archive. |
| `manifest` | `true` | `false` gives you the table and writes nothing to disk. |
| `units` | `MiB` | `MiB` is 1048576 bytes and `MB` is 1000000. The header says which. |
| `table-file` | none | Also write the table to this path. |

| output | value |
| --- | --- |
| `sha256` | The SHA-256 of the first archive. |
| `manifests` | The manifests it wrote, one path per line. |
| `table` | The Markdown table. |

The manifest is tab-separated with no header and lowercase hashes, one `hash  bytes  name` line per
file, with the archive itself first. A `.tar.gz` loses both extensions, so `app-1.0.0.tar.gz` gets
`app-1.0.0.integrity.tsv`.

Hash the archives on the runner that built them and read the manifests later. VRCFaceTracking
published a table of wrong hashes for three releases because it downloaded a release asset to hash
it, and `Start-Process gh api -RedirectStandardOutput` re-encodes a binary stream instead of copying
the bytes.

### publish-release

Creates the release and uploads the assets, and can check that the upload worked.

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

| input | default | what it does |
| --- | --- | --- |
| `tag` | required | Tag to publish. |
| `title` | the tag | Release title. |
| `notes-file` | none | Path to the Markdown notes. |
| `assets` | none | Files to upload, one per line. Entries with `*` or `?` are expanded, so `dist/python/*` works, and a glob that matches nothing is skipped. |
| `repository` | the calling repo | `owner/name` to publish to. |
| `target` | none | Commit-ish to attach the release to. |
| `prerelease` | `false` | Adds `--prerelease --latest=false`. |
| `draft-first` | `false` | Create a draft, check that every asset is attached, and only then publish it. |
| `delete-existing` | `false` | Delete a release that already exists for the tag first. |
| `verify-asset` | none | Asset whose digest to check after the upload. |
| `verify-sha256` | none | The SHA-256 that asset should have. |

Use `draft-first` where a failed upload would otherwise publish an empty release. If a re-run finds
a draft for the tag, such as one a failed run left behind, it checks that draft's assets and
publishes it the same way.

Given both `verify-asset` and `verify-sha256`, it polls the API until the uploaded asset's digest
matches, because an upload can report success before the asset is readable.

Your workflow has to clean up a half-made release itself, since that step has to run on failure:

```yaml
- name: Remove a partial release
  if: failure()
  run: gh release delete ${{ steps.tag.outputs.tag }} --yes 2>$null; $global:LASTEXITCODE = 0
  shell: pwsh
```

### commit-on-branch

Commits files to a branch through the GraphQL `createCommitOnBranch` mutation. GitHub signs those
commits on its side, so they pass a rule that requires verified signatures. A plain `git push` from
Actions doesn't.

```yaml
- uses: RealWhyKnot/workflows/commit-on-branch@v1
  with:
    headline: 'docs(changelog): promote Unreleased to ${{ steps.tag.outputs.tag }} [skip changelog]'
    paths: |
      CHANGELOG.md
```

| input | default | what it does |
| --- | --- | --- |
| `paths` | required | Files to commit, one per line, relative to the workspace. |
| `headline` | required | Commit subject. |
| `body` | none | Commit body. |
| `branch` | `main` | Branch to commit to. |
| `repository` | the calling repo | `owner/name` to commit to. |
| `skip-if-unchanged` | `true` | Do nothing when the files already match the branch. |
| `verify-signature` | `true` | Fail unless GitHub reports the new commit as verified. |
| `warn-on-failure` | `false` | Warn and carry on instead of failing the job, for example where a missed changelog commit shouldn't fail the release. |

It reads the branch head itself and sends it as `expectedHeadOid`, so if another commit landed
first the mutation fails and nothing is overwritten.

A commit made with `GITHUB_TOKEN` doesn't trigger workflows, which is what keeps the changelog
commit from re-running the job that made it.

### changelog-append

`changelog-append.yml` calls your repo's changelog script with `-Mode Append -Range ...` and commits
whatever changed through `commit-on-branch`, so the commit is signed and passes a
required-signatures rule.

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

| input | default | what it does |
| --- | --- | --- |
| `range` | the push | Commit range to append. |
| `changelog-paths` | `CHANGELOG.md` | Changelog files the script maintains, one per line. |
| `script` | `./.github/scripts/Update-Changelog.ps1` | The script that appends the entries. |

Keep the recursion guard on your own job. A `GITHUB_TOKEN` commit doesn't trigger workflows, but a
manual re-run or a different actor can still loop.

## Nightly betas

### nightly-beta

`nightly-beta.yml` tags `vYYYY.M.D.N-beta` when main has changes since the newest tag that pass the
[beta gate](#beta-gate), and does nothing otherwise. The date is taken in `timezone` rather than
UTC, so a late-evening commit still gets that day's date.

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

| input | default | what it does |
| --- | --- | --- |
| `timezone` | `America/Chicago` | Whose calendar date goes in the tag. |
| `suffix` | `beta` | Prerelease suffix for the tag. |
| `assert-sequence` | `true` | Run [`version-sequence`](#version-sequence) on the tag before pushing it. |
| `prerelease-suffix` | `[A-Za-z0-9]{4}` | The suffix regex that check accepts. |
| `dispatch-release` | `false` | Start your `release.yml` with the new tag. |
| `ignore-paths`, `release-types` | as `beta-gate` | Passed on to the gate. |
| `ci-workflow` | none | A workflow file, such as `ci.yml`, whose push run has to pass on the commit first. |

Its one output is `tag`, the tag it pushed, which is empty when nothing changed.

The release job stays in your repo, because `./` inside a shared workflow points at this
repository. If your `release.yml` only runs on a tag push, set `dispatch-release: true` and drop the
second job, since a tag pushed with `GITHUB_TOKEN` never fires that trigger.

`ci-workflow` runs [`wait-for-ci`](#wait-for-ci), so the calling job needs `actions: read` as well,
and the job timeout goes from 5 minutes to 30.

`nightly-beta-scripted.yml` is the same for repos whose own planner picks the tag. It runs on
`windows-latest` by default, runs the planner script, reads `has_changes` and `next_tag` from it,
and ANDs the result with the beta gate. On top of the gate and `ci-workflow` inputs it takes:

| input | default | what it does |
| --- | --- | --- |
| `runs-on` | `windows-latest` | Runner label. |
| `planner` | `./.github/scripts/Get-NightlyBetaPlan.ps1` | Script that decides the next tag and sets `has_changes` and `next_tag`. |
| `validate-scripts` | none | Self-test scripts to run before planning, one per line. |
| `no-changes-message` | `No app changes since the latest release tag.` | What to print when there's nothing to release. |
| `dispatch-release` | `true` | Start your `release.yml` with the new tag. |
| `timeout-minutes` | `15` | Job timeout. It's 45 when `ci-workflow` is set. |

### beta-gate

The check both nightly workflows use. It tells you whether any commit since the last tag changes
the program.

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

| input | default | what it does |
| --- | --- | --- |
| `base` | nearest tag | Ref to compare against. If it doesn't exist, everything counts as new and the gate passes. |
| `tag-glob` | `v*` | Which tags count when looking for the nearest one. |
| `ignore-paths` | none | Globs added to the built-in list, one per line. |
| `release-types` | `feat fix perf refactor revert` | Types that ship. Setting it replaces the list. |

| output | value |
| --- | --- |
| `has_changes` | `true` when a commit has a type that ships, or a `!`, and touches a path outside the ignore list. |
| `base` | The ref it compared against. |

The built-in ignore list is `.github/**`, `.githooks/**`, `docs/**`, `wiki/**`, `tests/**`,
`test/**`, `*.md`, `LICENSE*`, `NOTICE`, `.gitignore`, `.gitattributes`, `.editorconfig` and
`.vscode/**`. A `*` doesn't cross `/`, so `*.md` only matches Markdown at the repo root and
`src/help.md` still counts.

Merge commits are skipped, but the commits they bring in are checked. A subject that isn't a
conventional commit is judged by its paths alone. If no tag is reachable from HEAD the gate passes,
and if HEAD is tagged there's nothing to check. A shallow checkout has no tags, so every run passes.

### nightly-plan

Runs the beta gate and then works out the next nightly tag for the day. `nightly-beta.yml` uses it
as its planner. It doesn't create or push the tag.

```yaml
- id: plan
  uses: RealWhyKnot/workflows/nightly-plan@v1
  with:
    suffix: beta
```

| input | default | what it does |
| --- | --- | --- |
| `timezone` | `America/Chicago` | Whose calendar date goes in the tag. |
| `suffix` | `beta` | What goes after the hyphen. Leave it empty for a plain `vYYYY.M.D.N`. |
| `tag-glob`, `ignore-paths`, `release-types` | as `beta-gate` | Passed on to the gate. |

| output | value |
| --- | --- |
| `has_changes` | `true` when a commit since the nearest tag passes the beta gate. |
| `next_tag` | The tag to create. Empty when the gate fails. |

The tag is `vYYYY.M.D.N-suffix`, where `N` is one above the highest tag from the same day with any
suffix, so it always agrees with `version-sequence`. Like the gate, it needs `fetch-depth: 0`.

### wait-for-ci

Waits for a workflow's push run on a commit to pass, and fails if it didn't. I put it before
anything that tags or publishes, so a commit with red CI never ships. It needs `actions: read`.

```yaml
- uses: RealWhyKnot/workflows/wait-for-ci@v1
  with:
    workflow: ci.yml
```

| input | default | what it does |
| --- | --- | --- |
| `sha` | the triggering commit | Commit to check. |
| `workflow` | `ci.yml` | Workflow file whose runs count. |
| `repository` | the calling repo | `owner/name`. |
| `timeout-minutes` | `20` | How long to wait on a run that's still going. |
| `grace-minutes` | `3` | How long a person's commit with no run waits before its ancestors are checked. |
| `max-depth` | `30` | How many ancestors to look through. |

| output | value |
| --- | --- |
| `sha` | The commit whose run passed. |
| `run-url` | A link to that run. |

A run that passed counts even if an earlier attempt of it failed. Pull request runs don't count.

Some commits never get a run of their own, like a push that only touched ignored paths or a commit
pushed with `GITHUB_TOKEN` (the changelog bot's, for one). For those it walks back along the
first-parent history and uses the nearest commit that has a run. A commit from a person gets
`grace-minutes` first, in case its run hasn't started yet. Bot commits don't wait.

## Repo checks

### commit-subjects

The check that `commit-msg-check.yml` runs, as a step you can add to a job you already have. It
takes the same inputs, plus `range` to override the range it works out from the triggering event.
It needs a checkout with `fetch-depth: 0`.

```yaml
- uses: RealWhyKnot/workflows/commit-subjects@v1
  with:
    check-conventional: true
```

### workflow-syntax

Parses every tracked `.ps1`, `.psm1` and `.psd1` file and every inline `pwsh` block under
`.github/workflows`, and fails with a list of the syntax errors it finds. Pass `root` to scan a
folder other than the workspace.

```yaml
- uses: actions/checkout@v7
- uses: RealWhyKnot/workflows/workflow-syntax@v1
```

`${{ }}` expressions inside a block don't trip it. It only checks a block whose step sets
`shell: pwsh` before `run: |`. Steps that inherit `defaults.run.shell` or set `shell` after `run`
are skipped, and so are composite `action.yml` files.

### conformance

Fails when a repo has drifted from the shared setup. It looks for:

- a `RealWhyKnot/workflows` reference that isn't on `shared-ref`
- a `.githooks/commit-msg` or `prepare-commit-msg` that differs from the one in [`hooks/`](#hooks),
  ignoring line endings (a hook the repo doesn't have is skipped)
- no workflow calling `commit-msg-check.yml`, or a fork calling it without `forbidden-body-pattern`
- a missing `.github/dependabot.yml`, an ecosystem the repo uses that has no entry, or an entry
  without a `commit-message` prefix

```yaml
- uses: RealWhyKnot/workflows/conformance@v1
```

| input | default | what it does |
| --- | --- | --- |
| `shared-ref` | `v1` | The ref every shared reference must use. |
| `pins` | `warn` | `warn`, `fail` or `off` for stale third-party pins. |
| `ignore-ecosystems` | none | Ecosystems the repo leaves out on purpose, one per line. |
| `root` | the workspace | Repository to check. |

It works out the ecosystems from tracked files. `Cargo.toml` means cargo, project files and
`Directory.Packages.props` mean nuget, `package.json` means npm unless it's a Unity or VPM package,
`requirements*.txt` and `pyproject.toml` mean pip, and `go.mod` means gomod. Any workflow file
means github-actions.

A third-party action pinned to a branch, or to an older major version than its latest release, gets
a warning. `pins: fail` makes that an error and `pins: off` skips the lookups. SHA pins and local
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

| input | default | what it does |
| --- | --- | --- |
| `toolchain` | from the file, else `stable` | Toolchain to install. |
| `components`, `targets` | none | Added to what the file lists. Separate them with commas or newlines. |
| `working-directory` | `.` | Where `Cargo.lock` and `target` live, and where the search for `rust-toolchain.toml` starts. |
| `cache` | `true` | Set `false` to turn off the cargo cache. |
| `cache-key` | `cargo` | Key prefix. Give jobs that build different things a prefix each. |

Its one output is `toolchain`, the toolchain it installed.

Without a `toolchain` input it reads `channel`, `components` and `targets` from
`rust-toolchain.toml`, looking in `working-directory` and then each folder above it up to the repo
root, and falls back to `stable`. A version pinned in that file doesn't need repeating in the
workflow. The cache key is made from the OS, the toolchain and a hash of `Cargo.lock`.

### setup-nsis

Installs NSIS through Chocolatey unless `makensis /VERSION` already reports the version you asked
for, and puts it on `PATH`. Windows only. `version` is major.minor and defaults to `3.12`.

```yaml
- uses: RealWhyKnot/workflows/setup-nsis@v1
  with:
    version: '3.12'
```

## Repo files

### hooks

`commit-msg` rejects a subject with more than one build stamp, and `prepare-commit-msg` adds the
current one. They live here so their pattern matches `commit-msg-check.yml` exactly, and a test in
this repo fails if the two drift apart.

```
pwsh path/to/workflows/hooks/Install-Hooks.ps1 -RepoRoot . -Force
```

That copies both hooks into `.githooks/`, writes a `hook-config` for any setting that isn't the
default, and points `core.hooksPath` at the folder. Without `-Force` it won't overwrite a hook
you've edited.

Every repo gets the same hook files, and its own settings go in `hook-config`. Pass the same
settings you gave `commit-msg-check.yml`:

| flag | effect |
| --- | --- |
| `-StampPattern` | Narrow what counts as a build stamp. |
| `-NoStamp` | Don't stamp at all, and don't install `prepare-commit-msg`. |
| `-CheckConventional` | Require conventional subjects as well. |
| `-ForbiddenBodyPattern` | Reject a message that matches this. I use it to keep upstream issue numbers out of a fork. |
| `-VersionFile` | The file that holds the build stamp. Defaults to `version.txt`. |
| `-VersionInGitDir` | Keep that file inside `.git` so stamping never dirties the worktree. |

Merge, revert, `fixup!` and `squash!` subjects skip the conventional and body checks.

`pre-push` isn't shared, because each repo runs its own linter from it.

### lint

`lint/<lang>/` has my baseline formatter and linter configs, one folder per language. To copy them
into a repo:

```
pwsh path/to/workflows/lint/Install-Lint.ps1 -RepoRoot .
```

Without `-Lang` it picks the languages from the repo's tracked files and skips vendored code. Pass
`-Lang rust,csharp` to choose them yourself. Each file goes to the same relative path in the repo,
and a file that's already there and differs is left alone unless you pass `-Force`.

Everything in `lint/common/` goes into every repo. `vendored-paths.txt` lists code that keeps its
upstream style: `name/` matches a folder with that name at any depth, and `/path/` matches from the
repo root. It only has generic names like `vendor/`. Each repo lists its own upstream folders in a
`vendored-paths.local.txt` at its root, in the same format. Install-Lint adds those to the excludes
in the files it installs (ruff, pyright, ESLint, Prettier, `.editorconfig` and its copy of
`vendored-paths.txt`), and treats the result as current when it runs again.

`style_check.py` and the `style_*.py` modules next to it check what the linters can't: comments and
inline suppressions in Rust, C# and Python, files over 600 lines in any language, committed
generated C#, crates that don't inherit `[workspace.lints]`, and lint or format configs below the
repo root or inside project files. Each repo's gate runs it from the root with Python 3.11 or later,
with `-B` so it doesn't leave a `__pycache__` folder behind:

```
python -B style_check.py
```

It also fails when `vendored-paths.local.txt` has an entry that the installed `vendored-paths.txt`
doesn't, because the other configs won't have it either until Install-Lint runs again. It exits 1
if it finds anything and 2 if it can't run, which includes a local entry in the wrong format.

Files directly under `lint/<lang>/merge/` belong inside a file the repo already has, like the
`[workspace.lints]` table in `Cargo.toml`. The script checks that file for every line or key and
lists what's missing. A missing target file is only a note, unless the language's `install.psd1`
names it in a `Merge` entry. Folders under `merge/` hold variants that are only used when a rule
picks one.

I pin the TypeScript tools to exact versions in `lint/typescript/merge/package.json`, and
Dependabot checks those pins every week. Install-Lint lists each pin that a repo's `package.json`
has at a different version, so running it again in a repo after a bump shows what that repo still
needs to update.

An `install.psd1` in a language folder adjusts all this per repo. A rule can swap in a different
file (Unity repos get `merge/unity/.editorconfig`) or skip one that doesn't apply and give a reason
(Unity repos don't get the root `Directory.Build.props`). A rule that does neither is an old
per-repo tweak, and the script tells you to remove it. When two languages both ship
`.editorconfig`, their sections go into one file, and you settle any key they set differently. Any
other file that two languages both ship is left to you too. If anything needs doing by hand, the
script lists it and exits 1. Otherwise it exits 0.

### Dependabot

Every repo has a `.github/dependabot.yml`, and `conformance` checks that it covers everything the
repo uses. This is the layout I start from:

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

Replace the second entry with whatever the repo builds with. The `chore` prefix passes the
conventional subject check and doesn't count for the beta gate, so a dependency bump on its own
never tags a nightly. Schedules and limits can differ from repo to repo, since the check only looks
at coverage and the prefix.

## Versioning

Releases are tagged by date, `vYYYY.M.D.N`, like my other repos. `N` starts at 0 each day and goes
up by one for each release after that. Each release gets a GitHub release listing its changes, and
`v1` moves to the newest one. Releases up to `v1.6.2` used semantic versions, and those tags still
work.

In a release, the shared workflows call the actions at that same tag, so
`nightly-beta.yml@v2026.10.28.0` runs `nightly-plan@v2026.10.28.0`. Pinning or rolling back a
workflow covers everything it runs. On `main` they call `@v1`.

Any change to shipped code gets a release. Changes that only touch docs, tests or this repo's own
CI don't. A breaking change gets a new moving tag, `v2`, and `v1` stays where it was.

To pin a repo, use a release tag like `@v2026.10.28.0` and set `shared-ref` on `conformance` to
match, or it will flag the pin.

After a push to `main` I run `.github/scripts/New-Release.ps1`. It waits for CI to pass on the
commit, checks whether anything shipped since the last release, tags the release with the day's
next number and moves `v1`. `-PlanOnly` prints the tag without creating anything. The tag push runs
`release.yml`, which checks the tag's sequence, writes the notes with `release-notes` and publishes
the release.

CI runs every `Test-*.ps1` in the repo on ubuntu and windows, plus actionlint, `workflow-syntax`
and `conformance` on this repo. `commits.yml` runs `commit-msg-check.yml` on this repo's own pushes
and pull requests, with stamps off and conventional subjects required. It isn't meant for other
repos to call.
