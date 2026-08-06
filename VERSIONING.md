# VERSIONING

`kmsg` uses a major-plus-date release version.

## Source of truth

- The canonical version lives in the repo-root `VERSION` file.
- `VERSION` stores the version **without** the leading `v`.
- Git release tags use `v{VERSION}`.

Example:

```text
VERSION      -> 1.260424.0
Git tag      -> v1.260424.0
CLI version  -> 1.260424.0
```

## Format

Version format:

```text
MAJOR.YYMMDD.PATCH_COUNT
```

Tag format:

```text
vMAJOR.YYMMDD.PATCH_COUNT
```

Field rules:

- `MAJOR`: major release line, incremented manually when you want to signal a breaking or milestone release
- `YYMMDD`: 2-digit year suffix + 2-digit month + 2-digit day
- `PATCH_COUNT`: zero-based daily release counter; starts at `0` for the first release of a given `YYMMDD` and increments by `1` for each additional release that day

Examples:

- `1.260424.0`
- `1.260424.9`
- `2.261231.0`

Invalid examples:

- `1.26042.0`
- `1.261399.0`
- `0.260424.0`
- `v1.260424.0` in `VERSION` file

## Operational rules

- Update `VERSION` before creating a release tag.
- Keep `PATCH_COUNT` at `0` for the first release on a new `YYMMDD`.
- For additional releases on the same day, increment `PATCH_COUNT` by `1`.
- Reset `PATCH_COUNT` back to `0` when `YYMMDD` changes.
- Manual release tags and workflow inputs must match `vMAJOR.YYMMDD.PATCH_COUNT`.
- `YY` is interpreted as the year suffix in the 2000s for validation, so `260424` means `2026-04-24`.

## Bumping the version

Do **not** hand-edit `VERSION`. Bump it with the `make` targets below — they
wrap `scripts/headatever.sh`, which validates the next version, writes
`VERSION`, commits it as `chore(release): v<version>`, and creates the
annotated `v<version>` tag.

```bash
make version          # print the current version (read-only)
make release          # patch release: same day -> patch+1, new day -> date=today, patch=0
make release-major    # head release: head+1, date=today, patch=0
make release-push     # patch release, then `git push --follow-tags` (triggers the release workflow)
```

For the less common operations the `make` targets don't cover, call the script
directly:

```bash
scripts/headatever.sh patch --dry-run   # preview without writing
scripts/headatever.sh patch --push      # bump, then push commit + tag
scripts/headatever.sh date              # force a fresh release day (errors if already today)
scripts/headatever.sh set 2.260101.0    # set an explicit version
```

The script refuses to recreate an existing tag or move the date backwards, so a
bump always produces a unique, spec-valid version. Pushing the `v<version>` tag
triggers `release.yml` (universal binary build + GitHub release asset upload).
The script is vendored from the
[Headatever](https://github.com/channprj/headatever) spec.

## Compatibility notes

- Build-time version generation validates the `MAJOR.YYMMDD.PATCH_COUNT` format directly from `VERSION`.
- Release automation resolves the Git tag from `VERSION` as `v{VERSION}`.
- Release automation validates the tag format before building and checks the built binary's `--version` against the tag.

## Releasing

`make release-push` bumps `VERSION`, commits, tags, and pushes — but pushing the
tag is **not** enough to publish. This repository has never run a workflow from a
push event: every run in its history was a `workflow_dispatch`, including the ones
that look like tag releases. `release.yml` does declare `on: push: tags: ['v*']`,
and both workflows report `state=active`, so the block is not in the workflow
files; it sits at the repository level (this is a fork — see the Actions tab for a
"workflows aren't being run on this forked repository" opt-in).

So after tagging, start the release by hand:

```bash
gh workflow run release.yml --repo smallfish06/kmsg --ref main -f tag=v<version>
```

Then confirm the asset actually exists before pinning the version anywhere — the
consumer's updater downloads `kmsg-macos-universal` from the release and will
fail in a loop if the tag has no asset:

```bash
gh release view v<version> --repo smallfish06/kmsg --json assets
```

The same repository-level block is why `ci.yml` never runs on pushes or pull
requests. Until it is lifted, run its checks locally before pushing:

```bash
swift build && swift build -c release && python3 -m unittest discover tests
```
