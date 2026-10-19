# Endpoint coverage

Checked on 2026-10-17 against Apple's official [OpenAPI specification](https://developer.apple.com/sample-code/app-store-connect/app-store-connect-openapi-specification.zip),
version **4.5.1**, containing 1,001 path templates. ASC Bridge exposes 23 typed tools
for everyday app management. It does not expose a generic API proxy.

Every path below is relative to `https://api.appstoreconnect.apple.com`. Braced values
come from validated resource IDs, never caller-provided path fragments.

## Apps, versions and App Store metadata

| MCP tool | Apple method and path | Required arguments |
| --- | --- | --- |
| `asc_list_apps` | `GET /v1/apps` | none |
| `asc_get_app` | `GET /v1/apps/{appId}` | `appId` |
| `asc_list_versions` | `GET /v1/apps/{appId}/appStoreVersions` | `appId` |
| `asc_get_version` | `GET /v1/appStoreVersions/{versionId}` | `versionId` |
| `asc_create_version` | `POST /v1/appStoreVersions` | `appId`, `platform`, `versionString` |
| `asc_list_localizations` | `GET /v1/appStoreVersions/{versionId}/appStoreVersionLocalizations` | `versionId` |
| `asc_create_localization` | `POST /v1/appStoreVersionLocalizations` | `versionId`, `locale` |
| `asc_update_localization` | `PATCH /v1/appStoreVersionLocalizations/{localizationId}` | `localizationId`, at least one metadata field |
| `asc_list_app_infos` | `GET /v1/apps/{appId}/appInfos` | `appId` |
| `asc_list_app_info_localizations` | `GET /v1/appInfos/{appInfoId}/appInfoLocalizations` | `appInfoId` |
| `asc_create_app_info_localization` | `POST /v1/appInfoLocalizations` | `appInfoId`, `locale`, `name` |
| `asc_update_app_info_localization` | `PATCH /v1/appInfoLocalizations/{appInfoLocalizationId}` | `appInfoLocalizationId`, at least one metadata field |

Version localization fields: `description`, `whatsNew` (4,000 characters),
`promotionalText` (170), `keywords` (100 UTF-8 bytes), `marketingUrl`, `supportUrl`.
The byte bound follows Apple's [platform version reference](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information/);
non-ASCII keywords may reach the limit before 100 characters.

App Info fields: `name` (2–30 characters), `subtitle` (up to 30), `privacyPolicyUrl`,
`privacyChoicesUrl`, `privacyPolicyText`. Name and subtitle limits follow Apple's
[app information reference](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information/).
Bridge bounds privacy policy text to 4,000 characters and URL inputs to 2,000 characters.
URLs must be absolute HTTP(S) URLs without embedded credentials or whitespace; they
are metadata sent to Apple, never fetched by the bridge. Empty optional text/URL
values clear fields; omitted fields are unchanged. Names cannot be empty.

`asc_list_versions` accepts optional `platform`: `IOS`, `MAC_OS`, `TV_OS`, `VISION_OS`.
Version creation keeps the existing manual release policy. Discover the appropriate
editable App Info record with `asc_list_app_infos` before changing its localization.
Adding a language requires matching App Info and version locales in separate calls;
the bridge does not attempt a non-atomic, multi-request transaction.

## Builds and TestFlight

| MCP tool | Apple method and path | Required arguments |
| --- | --- | --- |
| `asc_list_builds` | `GET /v1/builds` | `appId` |
| `asc_get_build` | `GET /v1/builds/{buildId}` | `buildId` |
| `asc_get_version_build` | `GET /v1/appStoreVersions/{versionId}/build` | `versionId` |
| `asc_set_version_build` | `PATCH /v1/appStoreVersions/{versionId}/relationships/build` | `versionId`, `buildId` |
| `asc_list_beta_groups` | `GET /v1/apps/{appId}/betaGroups` | `appId` |
| `asc_list_beta_build_localizations` | `GET /v1/builds/{buildId}/betaBuildLocalizations` | `buildId` |
| `asc_create_beta_build_localization` | `POST /v1/betaBuildLocalizations` | `buildId`, `locale` |
| `asc_update_beta_build_localization` | `PATCH /v1/betaBuildLocalizations/{betaBuildLocalizationId}` | `betaBuildLocalizationId`, `whatsNew` |

Build list filters are explicit: `appId` maps to `filter[app]`, `platform` to
`filter[preReleaseVersion.platform]`, `buildNumber` to `filter[version]`,
`marketingVersion` to `filter[preReleaseVersion.version]`, `processingState` to
`filter[processingState]` (`PROCESSING`, `FAILED`, `INVALID`, `VALID`).
`buildNumber` and `marketingVersion` have a bridge bound of 100 characters.
Sort values are `version`, `-version`, `uploadedDate`, `-uploadedDate`,
`preReleaseVersion`, `-preReleaseVersion`; the default is `-uploadedDate`.

Attaching a build sends JSON:API linkage `{data:{type:"builds",id:"..."}}` and
handles Apple's empty `204` response as success with `{data:null,nextCursor:null}`.
It neither submits nor releases the version. Apple enforces build eligibility and
platform/version compatibility. The tool requires a build ID; detaching is not exposed.

Group listing requests a fixed set of summary fields: name, creation date, internal
group flag, all-build access flag, public-link-enabled flag and feedback flag.
It does not request invitation URLs or tester lists.

TestFlight localization `whatsNew` contains the What to Test text. The bridge bounds
it to 4,000 characters, allows empty text to clear it, and leaves supported locale
availability to Apple. This is separate from App Store version `whatsNew`.

## Customer reviews

| MCP tool | Apple method and path | Required arguments |
| --- | --- | --- |
| `asc_list_customer_reviews` | `GET /v1/apps/{appId}/customerReviews` | `appId` |
| `asc_get_customer_review_response` | `GET /v1/customerReviews/{reviewId}/response` | `reviewId` |
| `asc_upsert_customer_review_response` | `POST /v1/customerReviewResponses` | `reviewId`, `responseBody` |

Optional list filters: `territory` (three uppercase letters, e.g. `POL`), `rating`
(integer 1–5). They map to `filter[territory]` and `filter[rating]`. Apple validates
territory availability. Sort values: `rating`, `-rating`, `createdDate`, `-createdDate`;
the default is `-createdDate`.

The response tool creates or **replaces a public developer response** to the review,
as documented by [Apple](https://developer.apple.com/documentation/appstoreconnectapi/post-v1-customerreviewresponses).
It uses POST with a `review` relationship; there is no separate PATCH endpoint.
Publication in the App Store can be delayed. Bridge requires nonblank `responseBody`
and bounds it to 5,970 characters as a local input limit; the OpenAPI document does
not specify a maximum. No reply deletion is exposed.

## Shared behavior

All list tools accept `limit` (1–200, default 50) and an optional `cursor` returned
as `nextCursor` by the previous page. Reuse the same tool, parent ID and filters.
Cursors are at most 2,048 UTF-8 bytes and cannot contain control characters.
The bridge extracts only a cursor from Apple's next-page URL after validating its
scheme, host and exact expected path. It never follows caller-supplied URLs.
Resource links are stripped from results. Single-resource calls return the same
`{data,nextCursor}` envelope; `data:null` is allowed for optional build/reply
relationships. Apple HTTP errors remain errors,
including `404` when a related resource does not exist.

All inputs have closed schemas. Mutations have appropriate MCP hints, execute
without app confirmation dialogs, persist audit intent first and are never retried
automatically. All new metadata is subject to the existing audit sanitization.

## Other available Apple API areas

The [API overview](https://developer.apple.com/app-store-connect/api/) and OpenAPI
specification also cover the following areas, which are not implemented by this expansion:

| Area | Examples of further operations |
| --- | --- |
| Review and distribution | Review submissions, manual release requests, phased release, pre-orders |
| Assets | Screenshot sets, screenshots, previews and uploads |
| Monetization | In-app purchases, subscription groups, offers, price schedules and territories |
| TestFlight distribution | Tester invitations, membership and build distribution |
| Reporting | Analytics, sales, finance, performance and diagnostic reports |
| Developer account | Bundle IDs, certificates, profiles, devices, users and roles |
| Other products | Game Center, App Clips, custom product pages, experiments and Xcode Cloud |

These involve additional domain workflows, upload/download formats or account access.
The current tools retain the app's explicit credential and transport boundary.
