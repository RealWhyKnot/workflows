# workflows

Shared GitHub Actions I use across my own repos. A fix goes in here once instead of into a dozen copies.

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
caller granted. It can't add to it, and a missing permission shows up as a 403 deep inside the run.

| workflow | what it does | needs |
| --- | --- | --- |
| `commit-msg-check.yml` | Rejects commit subjects with more than one CalVer build stamp, optionally also non-conventional subjects and bodies matching a forbidden pattern. | `contents: read` |
| `version-guard.yml` | Fails if a `const string Version` reappears in `Editor/` or `Runtime/`. | `contents: read` |
| `dependabot-automerge.yml` | Turns on auto-merge for Dependabot updates of an allowed type. | `contents: write`, `pull-requests: write` |
| `changelog-append.yml` | Runs your `Update-Changelog.ps1` over the pushed range and commits the result back, signed. | `contents: write` |
| `nightly-beta.yml` | Tags a beta when main has changes since the last tag that pass the beta gate. | `contents: write`, plus `actions: read` with `ci-workflow` |
| `nightly-beta-scripted.yml` | Same, but your own planner script decides the tag. | `contents: write`, `actions: write` |
| `repo-checks.yml` | Runs `workflow-syntax`, `conformance` and actionlint with shellcheck. I call it from every repo's CI so drift fails the build. | `contents: read` |

`commit-msg-check.yml` inputs, all optional:

| input | default | meaning |
| --- | --- | --- |
| `check-stamp` | `true` | Count build stamps per subject and fail on more than one. |
| `stamp-pattern` | `\([0-9]{4}\.[0-9]+\.[0-9]+\.[0-9]+(-([A-Fa-f0-9]{4}\|beta))?\)` | What one stamp looks like. |
| `check-conventional` | `false` | Also require conventional subjects. |
| `conventional-pattern` | `feat\|fix\|chore\|ci\|docs\|refactor\|test\|perf\|diag\|style` | Which types count. |
| `forbidden-body-pattern` | none | Rejected anywhere in a non-merge commit body. I use it to keep upstream issue numbers out of a fork's history. |

Merge and revert subjects skip the conventional and body checks, because a merge subject is never
going to be a conventional commit. They're still counted for stamps.

`version-guard.yml` takes `error-hint`, extra text for the failure message that tells
people which pattern to use instead. `dependabot-automerge.yml` takes `update-types`
(newline-separated, default `version-update:semver-patch`) and `merge-method` (default `rebase`).

`repo-checks.yml` takes `pins` (default `warn`) and `ignore-ecosystems`, which go to `conformance`,
and `actionlint` (default `true`).

Dependabot gives its workflows a read-only token. Spell the write permissions above out on the
calling job or the merge call fails.

## checksums

Hashes release archives, writes an integrity manifest beside each one, and returns a Markdown table
for the notes.

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

| input | default | meaning |
| --- | --- | --- |
| `archives` | required | Newline-separated paths or globs. A pattern that doesn't match a file is an error. A renamed artifact fails the job instead of publishing a table with a row missing. |
| `contents` | sibling | Directory whose files are listed after each archive row, for a manifest that also covers what's inside the archive. Left unset, each archive picks up a directory beside it with the same base name, which is what a publish-then-compress job already produces. |
| `manifest-suffix` | `.integrity.tsv` | Suffix for the file written beside each archive. |
| `manifest` | `true` | Set `false` for a table and nothing on disk. |
| `units` | `MiB` | `MiB` is 1048576 bytes, `MB` is 1000000. The header says which. |
| `table-file` | none | Also write the table to this path. |

Outputs are `sha256` (the first archive), `manifests` and `table`.

The manifest is tab-separated, no header, lowercase hashes, `hash  bytes  name`, with the archive
itself on the first line. A `.tar.gz` drops both extensions: `app-1.0.0.tar.gz` writes
`app-1.0.0.integrity.tsv`.

Hash the archives on the runner that built them and read the manifests later. VRCFaceTracking
published a table of wrong hashes for three releases by downloading a release asset to hash it.
`Start-Process gh api -RedirectStandardOutput` re-encodes a binary stream instead of copying bytes.

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
| `previous-tag` | resolved | What to diff against. A stable tag diffs against the last stable one, and a prerelease against whatever came before it. |
| `title` | none | An H1 above the changes. |
| `extra` | none | Markdown appended after the changelog, for downloads and hashes. |

The only output is `file`, the path to the generated Markdown.

Commit authors are credited with a link to their profile, never a bare `@handle`. GitHub reads a
bare handle as a mention: it pings that person and adds them to the release's Contributors avatar
list, which is wrong when a fork's notes cover commits their upstream author never sent to my repo.
The link looks the same and pings nobody. Bots like `dependabot[bot]` are named in plain text.
Their login isn't a profile path.

Commits are grouped by conventional-commit prefix into Breaking Changes, Features, Bug Fixes,
Performance, Changes, Documentation, Build, CI, Tests, Chores and Other. A `type!:` subject goes to
Breaking Changes. Merge commits and anything with `[skip changelog]` are dropped, and a trailing
CalVer build stamp like `(2026.9.7.1-A528)` is stripped from the subject.

Authors are resolved to their GitHub logins through the commits API, which credits outside
contributors correctly. If the API can't be reached, it falls back to `git log` and the raw commit
author name. A first release lists every commit up to the tag. The API call needs `GH_TOKEN`, and
the action passes `github.token` for you.

Requires `fetch-depth: 0` and `fetch-tags: true` on the checkout, or there's no history to read.

## commit-subjects

The check behind `commit-msg-check.yml`, if you want it as a step inside a job you already have.
Same inputs, plus `range` to override the range it works out from the triggering event. It needs a
checkout with `fetch-depth: 0`.

```yaml
- uses: RealWhyKnot/workflows/commit-subjects@v1
  with:
    check-conventional: true
```

## workflow-syntax

Parses every tracked `.ps1`, `.psm1` and `.psd1` file and every inline `pwsh` block under
`.github/workflows`, then fails with a list of the syntax errors it found.

```yaml
- uses: actions/checkout@v7
- uses: RealWhyKnot/workflows/workflow-syntax@v1
```

`${{ }}` expressions inside a block are fine. A block only gets checked when its step sets
`shell: pwsh` above `run: |`. Steps that inherit `defaults.run.shell` or put `shell` after `run` are
skipped, and so are composite `action.yml` files. Pass `root` to scan somewhere other than the
workspace.

## resolve-tag

Validates the tag being released and tells you what it is.

```yaml
- id: tag
  uses: RealWhyKnot/workflows/resolve-tag@v1
  with:
    tag: ${{ inputs.tag }}
```

With no `tag` it falls back to the ref that triggered the run. One step covers both a tag push and a
manual re-release. Outputs `tag`, `version` (the tag without its `v`), `prerelease`, `channel`
(`beta` or `release`) and `sha`, the commit the tag points at.

| input | default | meaning |
| --- | --- | --- |
| `tag` | the triggering ref | Tag to release. |
| `tag-pattern` | `^v\d{4}\.\d+\.\d+\.\d+(-([A-Fa-f0-9]{4}\|beta))?$` | What a valid tag looks like. |
| `prerelease-pattern` | `-beta` only | Which tags count as prereleases. Widen it if every suffix should. |
| `require-tag-exists` | `true` | Fail unless the tag resolves to a commit in the checkout. |

I keep the two patterns separate because a `-A1B2` tag is valid but isn't a beta, and some of my repos
want it treated one way and some the other.

## version-sequence

Fails unless a CalVer tag uses the next free revision for its day.

```yaml
- uses: RealWhyKnot/workflows/version-sequence@v1
  with:
    tag: ${{ steps.tag.outputs.tag }}
```

A day starts at `.0`. After that each tag is one above the highest same-day tag, whatever its
suffix. The tag being checked is left out of the count, and re-running a release for a tag that
already exists still passes. Check out with `fetch-depth: 0` or the earlier tags aren't there to
count.

`prerelease-suffix` is a regex for the part after the hyphen. Its default `[A-Za-z0-9]{4}` accepts
`-beta` and `-A1B2` but not `-rc.1`. It only decides whether the tag itself is valid. I pass
`[A-Za-z0-9][A-Za-z0-9.-]*` in repos that use any suffix. Set `repo-root` to read tags from another
checkout.

## publish-release

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

An asset entry containing `*` or `?` is expanded. `dist/python/*` works, and a glob that doesn't
match anything is skipped.

`prerelease: true` adds `--prerelease --latest=false`. `draft-first: true` creates a draft, confirms
every asset is attached, and only then publishes it. Use it when a failed upload would otherwise
publish an empty release. A re-run that finds a draft for the tag, like one a failed run left
behind, checks its assets and publishes it the same way. `delete-existing: true` replaces an
existing release for the tag. Give it `verify-asset` and `verify-sha256` together and it polls the
API until the uploaded digest matches. An upload can report success before the asset is readable.

Cleaning up a half-made release is left to your workflow, because it has to run on failure:

```yaml
- name: Remove a partial release
  if: failure()
  run: gh release delete ${{ steps.tag.outputs.tag }} --yes 2>$null; $global:LASTEXITCODE = 0
  shell: pwsh
```

## commit-on-branch

Commits files back to a branch through the GraphQL `createCommitOnBranch` mutation instead of
`git push`. GitHub signs those commits server-side. They pass a "commits must have verified
signatures" rule, and a plain push from Actions doesn't.

```yaml
- uses: RealWhyKnot/workflows/commit-on-branch@v1
  with:
    headline: 'docs(changelog): promote Unreleased to ${{ steps.tag.outputs.tag }} [skip changelog]'
    paths: |
      CHANGELOG.md
```

It reads the branch head itself and sends it as `expectedHeadOid`. If another commit got there
first, the mutation fails instead of overwriting it. By default it does nothing when the files
already match the branch, and fails if GitHub doesn't report the new commit as verified. Set
`warn-on-failure: true` where a missed changelog commit shouldn't fail the release.

A commit made with `GITHUB_TOKEN` doesn't trigger workflows. That's what stops the changelog commit
from re-running the job that made it.

## changelog-append

Calls your repo's `Update-Changelog.ps1 -Mode Append -Range ...`, then commits whatever changed
through `commit-on-branch`. The commit is signed and passes a required-signatures rule.

```yaml
jobs:
  append:
    if: ${{ github.event_name == 'workflow_dispatch' || (github.actor != 'github-actions[bot]' && !contains(github.event.head_commit.message, '[skip changelog]')) }}
    uses: RealWhyKnot/workflows/.github/workflows/changelog-append.yml@v1
    with:
      range: ${{ inputs.range }}
```

Keep the recursion guard on your own job. A commit made with `GITHUB_TOKEN` doesn't trigger
workflows, but a manual re-run or a different actor can still loop. `changelog-paths` takes a
newline-separated list for repos that keep more than one changelog.

## nightly-beta

Tags `vYYYY.M.D.N-beta` when main has changes since the newest tag that pass the beta gate, and
does nothing otherwise. A commit passes when its type is `feat`, `fix`, `perf`, `refactor` or
`revert` (or it has a `!`) and it touches a path outside the ignore list. `release-types` and
`ignore-paths` change those. The date comes from `timezone` (default `America/Chicago`), not UTC.
A late-evening commit still gets that day's date.

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

The release job stays in your repo. `./` inside a shared workflow would resolve to this repository,
not yours. If your `release.yml` only triggers on a tag push, set `dispatch-release: true` instead
and drop the second job. A tag pushed with `GITHUB_TOKEN` never fires that trigger.

Set `ci-workflow: ci.yml` to tag only after that workflow has passed on the commit. It runs
`wait-for-ci`, so the calling job needs `actions: read` too. With it set, the job timeout goes from
5 minutes to 30, or 45 for the scripted one.

`nightly-beta-scripted.yml` works the same way for repos whose own planner decides the tag. It runs
`.github/scripts/Get-NightlyBetaPlan.ps1`, expects `has_changes` and `next_tag` outputs from it, and
ANDs the result with the beta gate.

## beta-gate

The check behind both nightly workflows. It says whether any commit since the last tag changes the
program.

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

Outputs are `has_changes` (`true` or `false`) and `base`, the ref it compared from.

| input | default | meaning |
| --- | --- | --- |
| `base` | nearest tag | Ref to compare from. If it doesn't exist, everything counts as new and the gate passes. |
| `tag-glob` | `v*` | Which tags count when looking for the nearest one. |
| `ignore-paths` | none | Newline-separated globs added to the built-in list. |
| `release-types` | `feat fix perf refactor revert` | Types that ship. Setting it replaces the list. |

The built-in ignore list is `.github/**`, `.githooks/**`, `docs/**`, `wiki/**`, `tests/**`,
`test/**`, `*.md`, `LICENSE*`, `NOTICE`, `.gitignore`, `.gitattributes`, `.editorconfig` and
`.vscode/**`. A `*` stops at `/`. `*.md` only matches Markdown at the repo root, and `src/help.md`
still counts.

Merge commits are skipped but the commits they bring in are checked. A subject that isn't a
conventional commit is judged on its paths alone. With no tag reachable from HEAD the gate passes,
and a tag on HEAD means there's nothing to check. A shallow checkout has no tags, which makes every
run pass.

## nightly-plan

Runs the beta gate, then picks the next same-day nightly tag. It's the planner inside
`nightly-beta.yml`. It doesn't create or push the tag.

```yaml
- id: plan
  uses: RealWhyKnot/workflows/nightly-plan@v1
  with:
    suffix: beta
```

Outputs `has_changes` and `next_tag`, which is empty when the gate fails. The tag is
`vYYYY.M.D.N-suffix`, with `N` one above the highest same-day tag of any suffix, so it always agrees
with `version-sequence`. Like the gate, it needs `fetch-depth: 0`.

| input | default | meaning |
| --- | --- | --- |
| `timezone` | `America/Chicago` | Whose calendar date goes in the tag. |
| `suffix` | `beta` | Text after the hyphen. Empty gives a plain `vYYYY.M.D.N`. |
| `tag-glob`, `ignore-paths`, `release-types` | as `beta-gate` | Passed through to the gate. |

## wait-for-ci

Waits for a workflow's push run to pass on a commit, and fails if it didn't. I put it in front of
anything that tags or publishes, so a commit with red CI never ships.

```yaml
- uses: RealWhyKnot/workflows/wait-for-ci@v1
  with:
    workflow: ci.yml
```

A run that passed counts even if an earlier attempt failed. Pull request runs don't count. If a run
is still going, it waits up to `timeout-minutes`.

Some commits never get a run of their own: a push that only touched ignored paths, or a commit pushed
with `GITHUB_TOKEN`, like the changelog bot's. For those it walks back the first-parent history and
uses the nearest commit that has a run. A commit from a person gets `grace-minutes` first, in case
its run hasn't started yet. Bot commits don't wait.

Needs `actions: read`. Outputs `sha`, the commit whose run passed, and `run-url`.

| input | default | meaning |
| --- | --- | --- |
| `sha` | the triggering commit | Commit to check. |
| `workflow` | `ci.yml` | Workflow file whose runs count. |
| `repository` | the calling repo | `owner/name`. |
| `timeout-minutes` | `20` | How long to wait on a run that's still going. |
| `grace-minutes` | `3` | How long a person's commit with no run gets before its ancestors are checked. |
| `max-depth` | `30` | How many ancestors to look through. |

## conformance

Fails when a repo has drifted from the shared setup. It checks for:

- a `RealWhyKnot/workflows` reference that isn't on `@v1`
- a `.githooks/commit-msg` or `prepare-commit-msg` that differs from `hooks/`, ignoring line
  endings (a hook the repo doesn't have is skipped)
- no workflow calling `commit-msg-check.yml`, or a fork calling it without `forbidden-body-pattern`
- no `.github/dependabot.yml`, an ecosystem the repo uses with no entry, or an entry with no
  `commit-message` prefix

The ecosystems come from tracked files. `Cargo.toml` means cargo, project files and
`Directory.Packages.props` mean nuget, `package.json` means npm unless it's a Unity or VPM package,
`requirements*.txt` and `pyproject.toml` mean pip, and `go.mod` means gomod. Any workflow means
github-actions.

A third-party action pinned to a branch, or to an older major than its latest release, gets a
warning. `pins: fail` turns that into an error and `pins: off` skips the lookups. SHA pins and local
actions are left alone.

```yaml
- uses: RealWhyKnot/workflows/conformance@v1
```

| input | default | meaning |
| --- | --- | --- |
| `shared-ref` | `v1` | The ref every shared reference must use. |
| `pins` | `warn` | `warn`, `fail` or `off` for stale third-party pins. |
| `ignore-ecosystems` | none | Newline-separated ecosystems the repo leaves out on purpose. |
| `root` | the workspace | Repository to check. |

## setup-rust

Installs a toolchain with rustup's minimal profile, makes it the default, and caches the cargo
registry, git checkouts and `target`.

```yaml
- uses: RealWhyKnot/workflows/setup-rust@v1
  with:
    components: rustfmt, clippy
```

With no `toolchain` it reads `channel`, `components` and `targets` from `rust-toolchain.toml` in
`working-directory` or the nearest folder above it, up to the repo root, then falls back to
`stable`. A version pinned in that file doesn't need
repeating in the workflow. The cache key is the OS, the toolchain and a hash of `Cargo.lock`.

| input | default | meaning |
| --- | --- | --- |
| `toolchain` | from the file, else `stable` | Toolchain to install. |
| `components`, `targets` | none | Added to whatever the file lists. Comma or newline separated. |
| `working-directory` | `.` | Where `Cargo.lock` and `target` live, and where the search for `rust-toolchain.toml` starts. |
| `cache` | `true` | Turn the cargo cache off. |
| `cache-key` | `cargo` | Key prefix. Jobs that build different things should each get their own. |

## setup-nsis

Installs NSIS through Chocolatey unless `makensis /VERSION` already reports the version you asked
for, then puts it on `PATH`. Windows only.

```yaml
- uses: RealWhyKnot/workflows/setup-nsis@v1
  with:
    version: '3.12'
```

## hooks

`commit-msg` rejects a subject with more than one build stamp, and `prepare-commit-msg` appends the
current one. They're kept here so the pattern matches `commit-msg-check.yml` exactly. A test in this
repo fails if the two ever drift apart.

```
pwsh path/to/workflows/hooks/Install-Hooks.ps1 -RepoRoot . -Force
```

That copies both into `.githooks/`, writes a `hook-config` for anything non-default, and points
`core.hooksPath` at it. Without `-Force` it doesn't overwrite a hook you've edited.

The hook files are identical in every repo. Per-repo settings go in `hook-config`. Pass the same
settings you gave `commit-msg-check.yml`:

| flag | effect |
| --- | --- |
| `-StampPattern` | Narrow what counts as a build stamp. |
| `-NoStamp` | Skip stamping entirely, and don't install `prepare-commit-msg`. |
| `-CheckConventional` | Also require conventional subjects. |
| `-ForbiddenBodyPattern` | Reject a message matching this, for keeping upstream issue numbers out of a fork. |
| `-VersionFile` | Name of the file holding the build stamp. Defaults to `version.txt`. |
| `-VersionInGitDir` | Keep that file inside `.git` and stamping never dirties the worktree. |

Merge, revert, `fixup!` and `squash!` subjects skip the conventional and body checks.

`pre-push` isn't shared because each repo runs its own linter from it.

## Dependabot

Every repo has a `.github/dependabot.yml`, and `conformance` checks that it covers what the repo
uses. This is the layout I start from:

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

Swap the second entry for whatever the repo builds with. The `chore` prefix passes the conventional
subject check, and the beta gate doesn't count it, so a dependency bump on its own never tags a
nightly. Schedules and limits can differ per repo. The check only looks at coverage and the prefix.

## Versioning

Pin to `@v1`. That tag moves as fixes are released, and every repo picks them up without a bump.
Pin to a full tag like `@v1.0.0` if you want a repo frozen, and set `shared-ref` to match or
`conformance` will flag it.

Because `v1` moves, CI here runs every `Test-*.ps1` in the repo on both ubuntu and windows, plus
actionlint, `workflow-syntax` and `conformance` over this repo, before I move the tag. `commits.yml` runs `commit-msg-check.yml` on
this repo's own pushes and pull requests, with stamps off and conventional subjects required. It
isn't meant to be called from other repos.
