# Product

Local macOS 14+ app for one App Store Connect team key. The user imports a `.p8`
and enters Key ID and Issuer ID in a native UI. A connection test lists one app.
The app exposes local MCP and displays connection settings and persistent history.
Closing the window keeps the app available; quitting the app stops MCP.

## Tools
- `asc_list_apps`: discover app IDs.
- `asc_list_versions`: list versions for an app, optionally filter by platform.
- `asc_list_localizations`: list version localizations and existing text.
- `asc_create_version`: create a version for an app and platform; default manual release.
- `asc_create_localization`: add localized version text for a locale.
- `asc_update_localization`: update existing description, whatsNew, promotionalText.

List calls are bounded and expose safe pagination. Mutation tools execute immediately
without app approval dialogs. Tool schemas reject unknown arguments. No submission,
publishing, deleting, uploads, analytics or raw HTTP in this first release.
Apple's roles and editable-state rules still apply. New version locales also need
matching App Info locales in ASC; this MVP does not edit App Info localizations.

## History
Record all MCP methods/notifications, tool names, sanitized input, request ID, time,
duration, success/error and useful safe result summaries. Also record rejected and
malformed attempts without their raw secret-bearing payloads. Keep history across
launches. Do not store HTTP authorization, private keys or signed JWTs. History is
local; no automatic deletion or remote upload.

