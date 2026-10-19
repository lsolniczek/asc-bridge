## Problem

What problem does this change solve?

## Change

What changed, and what should reviewers focus on?

## Verification

How was this change checked? Include relevant commands or manual steps.

## Security invariants

- [ ] The diff, fixtures, logs, and documentation contain no real credentials, `.p8` contents, JWTs, bearer tokens, Keychain data, or unredacted audit records.
- [ ] MCP/API changes preserve typed operations, loopback-only access, authentication, and request auditing; Apple mutation requests are not automatically retried.
- [ ] Credential import and deletion remain in the app UI.
