# Publish to GitHub

Target account: `lastness09`

Repository: `lastness09/Video-Sampler-for-Fingersonic-Beats`

The source commit and English release files are prepared locally. The publication script creates a public repository when needed, pushes `main` and the version tag without force, uploads all nine prepared release files, and publishes the test build as a GitHub prerelease.

Run this from the project root:

```bash
zsh scripts/publish_to_github.sh
```

You can also double-click `scripts/Publish to GitHub.command`. GitHub CLI is required. If it has not been authenticated, the script starts its standard browser sign-in. Complete that sign-in as `lastness09`; the script checks the authenticated account before publishing anything.

The script refuses to publish under another account, change an existing private repository to public, replace a remote pointing elsewhere, force-push a branch, or reuse a version tag pointing to a different commit. Re-running it may replace release assets with the prepared files for the same version.

Source code remains in Git. App ZIPs and other distribution downloads are uploaded as release assets. `.build`, local backups, user-specific Xcode settings, and `dist` are excluded from source commits.

After publication, verify the repository and release URLs reported by the script, and compare the uploaded asset sizes or downloaded hashes with `SHA256SUMS.txt`.
