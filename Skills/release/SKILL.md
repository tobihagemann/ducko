---
name: release
description: This skill should be used when the user asks to "cut a release", "publish a new version", "prepare a release", "tag a release", or "ship it". Covers the full pipeline: update CHANGELOG.md, tag, and push to trigger GitHub Actions CI which builds, signs, notarizes, creates DMG, generates Sparkle appcast, and publishes a GitHub Release.
---

# Release

Releases are built exclusively via GitHub Actions — never locally.

## Step 1: Update CHANGELOG.md

Discover user-facing changes since the last release:

```bash
git log $(git describe --tags --abbrev=0)..HEAD --oneline
```

Read PR descriptions via `gh pr view <number> --json title,body` to understand each change's user-facing impact. Do not rely on commit messages alone — they describe implementation, not user outcomes.

Add a new section under the version heading. See [references/changelog-format.md](references/changelog-format.md) for format and style guidance.

```markdown
## x.y.z

- Added feature X.
- Fixed bug Y.
```

## Step 2: Commit and Push

```bash
git add CHANGELOG.md
git commit -m "Prepare release x.y.z"
git push origin main
```

## Step 3: Tag and Push

```bash
git tag x.y.z
git push origin x.y.z
```

The `release.yml` workflow automatically builds, signs, notarizes, creates the DMG, generates the Sparkle appcast, commits `appcast.xml` to `main`, and publishes a GitHub Release with `.zip`, `.dmg`, checksums, and release notes from `CHANGELOG.md`.

## Dry Run

Use `workflow_dispatch` from the Actions tab with "Dry run" checked. This runs the full pipeline but skips creating the GitHub Release. Artifacts are always uploaded.

## Local Fallback

If CI is unavailable, see [references/local-release.md](references/local-release.md) for the manual release procedure.

