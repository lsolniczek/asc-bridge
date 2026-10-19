# Security policy

## Reporting a vulnerability

Use this repository's **Security → Report a vulnerability** action when private
vulnerability reporting is enabled. GitHub describes the process in its
[private reporting guide](https://docs.github.com/en/code-security/how-tos/report-and-fix-vulnerabilities/report-privately).
If that action is unavailable, open an issue asking for a private security contact.
Include no vulnerability details or credentials in that public issue.

In a private report, describe the affected version/commit, impact and reproduction
steps using synthetic credentials. Do not send real Apple private keys, signed
JWTs, local MCP tokens, complete MCP configuration or unredacted audit history.
There is no guaranteed response time or paid bug bounty.

## Supported versions

Security fixes target the latest default branch. Older commits and locally
modified builds have no promised maintenance or backported fixes.

## Intended boundary

ASC Bridge stores the App Store Connect team key in the macOS Keychain and signs
Apple requests inside the app. MCP exposes typed operations over authenticated
loopback HTTP. It never provides credential import, export or token-signing tools.

The separate MCP token authorizes access to the broker. A client holding it can
perform the exposed mutations immediately, within the Apple key's permissions.
Metadata and review text can be included in local audit history. Neither a fully
privileged process that can inspect application memory nor an agent that can
modify the app is isolated by this boundary.

Read [docs/security.md](docs/security.md) for transport, audit, signing and
credential-handling details.
