# ASC Bridge

Small local macOS app: Keychain credentials → App Store Connect client → MCP tools.

## Map
- `ARCHITECTURE.md`: modules, interfaces and dependency direction.
- `docs/product.md`: MVP behavior and tool scope.
- `docs/security.md`: credential boundary, transport and audit rules.
- `docs/references.md`: official API and SDK sources.
- `docs/plans/`: implementation progress and decisions.
- `Sources/BridgeCore`: contracts, credentials, ASC client.
- `Sources/BridgeMCP`: MCP transport, tools and persistent audit history.
- `Sources/ASCBridge`: SwiftUI app and composition.

## Verification
- `swift test --build-system swiftbuild` (synthetic credentials and stubbed Apple HTTP only).
- `swift build --build-system swiftbuild -c release`.
- `python3 scripts/localizations.py check` after the debug build; String Catalogs require Swift Build.
- `./scripts/check.sh` for the local quality gate once available.
- Review the real integrated diff with a fresh read-only worker before completion.

## Invariants
- Never read a user's real `.p8`, Keychain credentials or bearer token through agent tools.
- Never put private keys, JWTs or local MCP auth headers in logs or MCP responses.
- The app UI is the only credential import/delete surface; MCP has no credential tools.
- Bind HTTP to `127.0.0.1` only and require a separate local bearer token.
- No arbitrary Apple URL, raw HTTP or shell tools. Use explicit typed operations.
- Log every MCP request and notification, including failures. Persist intent before ASC mutations.
- Do not retry Apple mutation requests automatically.
- No in-app confirmation for MCP mutations; the user explicitly requested this.
- Parallel write workers must use separate Git worktrees. Managers own workflow documents.

