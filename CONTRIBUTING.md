# Contributing to ASC Bridge

Bug reports, documentation improvements and focused pull requests are welcome.
For security issues, follow [SECURITY.md](SECURITY.md).
Please follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Development setup

Use macOS with Xcode 26.4 / Swift 6.3 and Python 3.9 or later. The application
targets macOS 14+. The manifest uses Swift tools 6.1, while the locked dependency
graph and CI are tested with Swift 6.3; the manifest alone is not a promise that
the full project builds with every Swift 6.1 toolchain.

Clone your fork, create a branch, then run:

```sh
./scripts/check.sh
./scripts/build-app.sh --debug
```

The checks use generated keys, stubbed Apple HTTP and an explicit synthetic MCP
server on port 43130. They do not need a developer account, a real `.p8` file or
Keychain access. The normal application listens on port 43129.

## Making a change

- Read [ARCHITECTURE.md](ARCHITECTURE.md) and [AGENTS.md](AGENTS.md) for module boundaries.
- Keep changes focused and preserve existing public tool names and arguments.
- Add meaningful regression coverage when changing behavior, especially request
  validation, Apple request bodies, redaction, audit persistence and transport rules.
- Run `./scripts/check.sh`; for packaging changes, also build the app and run
  `python3 scripts/smoke-mcp.py "dist/ASC Bridge.app/Contents/MacOS/ASCBridge"`.
- Update the endpoint documentation and both READMEs when changing user-facing tools.

Use `Package.resolved` for reproducible dependency versions. After an intentional
dependency update, run `swift package resolve`, regenerate the notices with
`python3 scripts/update-third-party-notices.py`, and include both resulting files.
The build verifies that the checked-in notices match the resolved dependencies.

## Credential and transport rules

Real credentials must never be used in automated tests or included in an issue,
pull request, screenshot, fixture or log. Generate synthetic keys in memory.
Keep credential import/delete in the app UI. MCP must not expose credential,
sign-token, arbitrary URL, raw HTTP or shell operations.

Bind to IPv4 loopback only, require a separate local bearer token, and keep
Host/Origin validation. Persist audit intent before Apple mutations. Never
automatically retry a mutation or forward authorization through redirects.
The product intentionally has no app confirmation dialog for MCP mutations.
See [the security boundary](docs/security.md) for details.

## Pull requests

Explain the problem, the resulting behavior and the checks you actually ran.
Use synthetic examples and include screenshots for visible UI changes. If a check
could not run, say which one and why. A maintainer will review the actual diff
before merging. There is no CLA; contributions are accepted under the project's
[MIT license](LICENSE), while upstream dependency licenses remain unchanged.
