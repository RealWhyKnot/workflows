# workflows

Shared GitHub Actions I use across my own repos, so a fix lands once instead of in a dozen copies.

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

## Versioning

Pin to `@v1`. That tag moves as fixes land, so every repo picks them up without a bump. Pin to a full
tag like `@v1.0.0` if you want a repo frozen.
