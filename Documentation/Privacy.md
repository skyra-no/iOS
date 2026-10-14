# Data and privacy

This describes the native SDK's explicit survey integration. Hosted survey and
backend retention policies are separate from native storage expiry.

## Data flow

| Data | Native behavior |
| --- | --- |
| Organisation and survey slug | Sent in the delivery URL and hosted page URL to request the explicit survey. |
| Visitor and session identifiers | Generated natively and passed to the hosted page for survey session and response handling. Supported progress can reuse those identifiers. |
| Language, device class, traits | Passed in hosted initialization. Traits are supplied by the integrating app; the SDK does not discover an app's user profile. |
| Dynamic Type scale | Passed to the hosted page for accessible layout. |
| Saved question progress and selections | Passed to the hosted page when resuming. Only the allowlisted state schema is persisted natively. |
| Entered answers | The hosted page sends answers to Skyra. Typed free text and recruitment values are not persisted by the native SDK, but can be submitted to the service. |

Production defaults are `https://survey.skyra.no` for hosted content and
`https://ingest.skyra.no` for delivery. The hosted page owns session initialization,
answer submission, and any content/font requests. Network requests can expose
ordinary transport metadata such as IP addresses to the receiving services;
native ephemeral mode does not prevent this.

## Native storage

The default backend uses app-local UserDefaults, namespaced by SDK and hosted
origin. It stores generated identity, survey outcome history, timestamps, and
supported unfinished progress. Visitor and survey records have a 365-day expiry
from their respective allocation/update; reads do not renew it. Expired records
are ignored or pruned when storage is accessed, rather than removed by a background
timer. Completed/rejected records retain history but clear active progress.

The snapshot allowlists survey/revision identity, language, question position and
history, selection IDs, and supported flags. It does not persist typed free text,
recruitment values, traits, or survey definitions. UserDefaults is not a secure
vault and the SDK does not add application-level encryption.

`.ephemeral` keeps native state for the SDK instance only. A custom `SkyraStorage`
controls its own persistence and must preserve atomic update semantics. The
WebView uses a nonpersistent website data store. Neither ephemeral option deletes
answers already accepted by the backend. `.fresh` starts a new session; it is not
a data-erasure operation or cooldown bypass.

## App privacy disclosures

The package bundles `PrivacyInfo.xcprivacy`, declaring UserDefaults required-reason
API use with reason `CA92.1` and System Boot Time API use with reason `35F9.1`.
Skyra uses system uptime to measure display delay; these measurements remain on the
device and are not saved or sent. The manifest is at
`Sources/Skyra/PrivacyInfo.xcprivacy` and is copied as a package resource. These are
required-reason API declarations, not a complete declaration of every datum
collected by an app or its hosted survey.

Before publication, confirm the service-side data inventory, retention and deletion
policy, and applicable collected-data/tracking declarations with the service owner.
The app's disclosures must account for its survey questions, supplied traits, and
use of responses. Native 365-day expiry must not be presented as backend retention.

Source references: `Storage.swift`, `SavedState.swift`, `BridgeMessages.swift`,
`Presentation.swift`, and `PrivacyInfo.xcprivacy` under `Sources/Skyra/`.
