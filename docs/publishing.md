# Publishing ASC Bridge on GitHub

The repository is prepared for an MIT-licensed source release. Creating a GitHub
repository, pushing commits, enabling account settings and publishing a release
are separate maintainer actions. The local preparation does not perform them.

## Preserve the existing repository

Publish from this development checkout to retain the existing commit history.
Do not delete `.git`, reinitialize the repository or squash its history as part of
publication. Commits retain their original author names and email addresses;
review that metadata before the first public push.

For future commits, you may use the address shown in your GitHub email settings.
Changing it does not remove metadata from old commits. The
[GitHub email privacy guide](https://docs.github.com/en/account-and-profile/how-tos/email-preferences/setting-your-commit-email-address)
explains how to find your own GitHub-provided `noreply` address.

Never add `.build/`, `dist/`, Keychain exports, real `.p8` files, local MCP
configuration, audit JSONL or signing credentials. The repository ignore rules
exclude common credential and generated-file formats. A source archive alone is
not a replacement for this Git repository's history.

## Verify the source

Run on macOS using the tools described in [CONTRIBUTING.md](../CONTRIBUTING.md):

```sh
./scripts/check.sh
./scripts/build-app.sh
python3 scripts/smoke-mcp.py "dist/ASC Bridge.app/Contents/MacOS/ASCBridge"
```

All automated checks use synthetic credentials and stubbed Apple HTTP. Dependency
notices are checked against `Package.resolved`. CI uses the same checks with Xcode
26.4.1 on a macOS 26 GitHub runner; its first hosted run happens after the first push.

## First public push

Install GitHub CLI and sign in locally if needed. Run these commands from the
existing repository, retaining its current history:

```sh
git status --short
git add .
git diff --cached --stat
git diff --cached --check
git commit -m "Prepare ASC Bridge for its first open-source release"
```

Review the staged files and commit identity before committing. No GitHub remote
is configured by the preparation work. After reviewing the final commit, create
the public repository and push. The example uses `asc-bridge`; choose another
repository name if needed:

```sh
gh repo create asc-bridge --public --source=. --remote=origin --push
```

If you create an empty repository through the GitHub website instead, do not have
GitHub add another README, license or `.gitignore`; those files are already included.
Use the remote URL GitHub provides and push `main`.

## GitHub settings after creation

- Set a description such as “Local macOS MCP bridge for App Store Connect, with
  Keychain credentials and persistent audit history.” Suggested topics:
  `macos`, `swift`, `swiftui`, `mcp`, `app-store-connect`, `developer-tools`.
- Enable Issues and private vulnerability reporting. The root
  [SECURITY.md](../SECURITY.md) describes private reporting and a fallback contact
  request. GitHub documents [enabling private reports](https://docs.github.com/en/code-security/how-tos/report-and-fix-vulnerabilities/configure-vulnerability-reporting/configure-for-a-repository).
- Enable available secret-scanning/push-protection and Dependabot security features.
  Weekly Swift and GitHub Actions updates are configured in `.github/dependabot.yml`.
- After a successful first CI run, protect `main` with pull-request review and the
  workflow's macOS check. Keep workflow permissions read-only; no Apple credentials
  are needed for CI.

## Dependency changes

After intentionally updating package versions:

```sh
swift package resolve
python3 scripts/update-third-party-notices.py
./scripts/check.sh
```

Review and commit `Package.resolved` and `THIRD_PARTY_NOTICES.md` together.
Upstream licenses and notice files are retained verbatim. The notice inventory
does not replace a review of additional assets or dependencies introduced later.

## Binary releases

Start with the source repository. `./scripts/build-app.sh` produces a locally
ad-hoc-signed app and includes the project and dependency notices. It does not
notarize the app or configure a Developer ID certificate. A locally built app's
Keychain access may be prompted again when its code identity changes.

Before a binary release, choose a distribution/signing/notarization policy, test
the archive on a clean Mac and update [CHANGELOG.md](../CHANGELOG.md). Preserve
bundle metadata when archiving with `ditto`:

```sh
ditto -c -k --sequesterRsrc --keepParent "dist/ASC Bridge.app" dist/ASC-Bridge-macOS.zip
```

Keep the `LICENSE` and `THIRD_PARTY_NOTICES.md` resources in the app. No workflow in
this repository automatically publishes binaries or creates GitHub releases.
