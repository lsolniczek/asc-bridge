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
- `asc_update_localization`: update existing localized version metadata.
- `asc_get_app`, `asc_get_version`: inspect a single app or version.
- `asc_list_app_infos`, `asc_list_app_info_localizations`: discover App Info IDs and localized metadata.
- `asc_create_app_info_localization`, `asc_update_app_info_localization`: manage localized name, subtitle and privacy metadata.
- `asc_list_builds`, `asc_get_build`: discover builds with bounded, typed filters.
- `asc_get_version_build`, `asc_set_version_build`: inspect or attach an existing build to a version.
- `asc_list_beta_groups`: inspect group summaries without tester lists or invitation links.
- `asc_list_beta_build_localizations`, `asc_create_beta_build_localization`,
  `asc_update_beta_build_localization`: read and manage TestFlight What to Test text.
- `asc_list_customer_reviews`, `asc_get_customer_review_response`,
  `asc_upsert_customer_review_response`: read reviews and create or replace public developer replies.

Version localization create/update also accepts keywords, marketingUrl and supportUrl.
All 23 tools and their Apple routes are documented in [endpoints.md](endpoints.md).

List calls are bounded and expose safe pagination. Mutation tools execute immediately
without app approval dialogs. Tool schemas reject unknown arguments. App submission,
app release, deletion, binary/asset uploads, analytics and raw HTTP remain outside
the tool surface. Customer review replies are public and POST replaces an existing
reply for the same review. Attaching a build does not submit or release the app.
Apple's roles and editable-state rules still apply. New locales need matching App Info
and version localizations; agents can create both explicitly in separate calls.

## History
Record all MCP methods/notifications, tool names, sanitized input, request ID, time,
duration, success/error and useful safe result summaries. Also record rejected and
malformed attempts without their raw secret-bearing payloads. Keep history across
launches. Do not store HTTP authorization, private keys or signed JWTs. History is
local; no automatic deletion or remote upload.

