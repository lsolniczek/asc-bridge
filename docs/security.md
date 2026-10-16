# Security boundary

The agent can invoke approved operations without receiving ASC credentials. There
are no MCP import, export, sign-token, arbitrary URL, arbitrary headers or shell tools.
The app loads the team key from an app-restricted macOS Keychain item and generates
ES256 JWTs in memory. All Apple requests target `https://api.appstoreconnect.apple.com`;
redirects must not forward authorization to another host.

Local MCP listens only on IPv4 loopback. A random separate MCP bearer token is
stored in Keychain and may be copied into the agent's MCP configuration. That token
permits calling the broker but does not reveal the Apple key. Reject unexpected Host
and browser Origin headers. Do not log either bearer token or raw HTTP headers.

Audit input uses schema allowlists and secret-pattern redaction, including malformed
and unknown calls. Write intent must reach disk before any Apple mutation. Audit
completion cannot be transactional with Apple's API; an interrupted call is shown as
unfinished and must be checked before a mutation is repeated. Never auto-retry writes.

Keychain restrictions depend on macOS code identity. Development ad-hoc rebuilds may
cause a system Keychain prompt; stable Developer ID signing is recommended for repeated
use. This is not an in-app action approval. Do not grant Keychain access to an agent,
terminal, interpreter or `security` CLI. Original imported `.p8` files remain where
the user placed them; the app never silently deletes the user's original. A fully
privileged agent able to read those files or modify the app is outside this boundary.

