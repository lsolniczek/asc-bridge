# Architecture

`ASCBridge` (SwiftUI composition) depends on `BridgeMCP` and `BridgeCore`.
`BridgeMCP` depends on `BridgeCore`, the official MCP SDK and Hummingbird.
`BridgeCore` depends only on Apple Foundation, Security and CryptoKit.

The GUI owns credential import. `KeychainCredentialStore` implements `CredentialStore`.
`ASCClient` implements `ASCServing`; it loads credentials and signs short-lived ES256 JWTs
internally. `MCPHost` exposes only the operations in `ASCOperation` over loopback HTTP.
Each HTTP exchange uses an independent SDK server/transport to isolate client-chosen
JSON-RPC IDs. The host validates auth before dispatch. `AuditStore` persists sanitized
request intent and completion records and provides a history projection to SwiftUI.

Public contracts are in `Sources/BridgeCore/Contracts.swift`. Cross-module changes
must preserve these or be coordinated by the manager.

Persistent state: private ASC credential and separate local MCP token in Keychain;
audit JSONL under Application Support/ASCBridge with owner-only permissions.
No database, account service, telemetry backend or cloud hosting.

