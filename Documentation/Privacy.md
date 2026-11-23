# Data and privacy

This describes what the Swift package stores and sends. Surveys are shown and
answers are sent by the Skyra widget in the app's web view, so that traffic and Skyra's backend
retention are outside this document.

## What is sent

The package makes one kind of request: `POST /v1/decide` to the decision service,
`https://ingest.skyra.no` by default, each time the app calls `getSurveys`.

| Data | Source |
| --- | --- |
| Organisation | The configuration. |
| Device class | `mobile` or `tablet`, from the device. |
| App language | The configured `language`, if set. |
| Device language | The device's first preferred language, such as `nb-NO`. |
| Time zone | The device's time zone identifier, such as `Europe/Oslo`. |
| Traits | `channel: app`, plus whatever the app supplies in the configuration and in the call. The SDK does not discover anything about the user. |
| Visitor ID | A ULID the SDK generates on first use. |
| Survey states | For each survey Skyra has recorded: its state, the time of that state, and its session ID when it has one. |
| `User-Agent` | The SDK version, the app's name and version, and the OS name and version. |
| `Accept-Language` | The device's preferred languages. iOS adds this header to every request. |

The request has a 1.5-second timeout and no retries. It uses no cache, cookies or
credentials, and it does not follow redirects to another address. Like any network
request, it exposes transport metadata such as the IP address to the receiving
service. Ephemeral persistence does not change that.

## What is stored

The default backend is app-local UserDefaults under the `no.skyra.sdk` prefix, one
value per organisation. It holds:

- the visitor ID,
- for each survey, the last state (`Selected`, `Capture`, `Completed` or `Rejected`),
  the time of that state, and the session ID when there is one,
- for a survey the visitor is part-way through in a web view, the widget's progress:
  which question they are on and which options they chose so far.

It never holds written answers, traits or survey definitions. Progress is not sent to
the decision service. UserDefaults is not a secure
vault and the SDK adds no encryption of its own.

A survey entry is dropped 400 days after its state last changed. At most 200 survey
entries and 1 MB of progress are kept; the oldest are dropped first. Entries are pruned
when the state is next read or written; there is no background timer. The visitor ID
does not expire. It is removed when the app's storage is cleared, for example when
the app is deleted.

`getSurveys` and `state()` create the visitor ID on first use. `getSurveys` writes
nothing about the surveys it returns. Survey entries are written only by `sync`.

`.ephemeral` persistence keeps the state in memory for the lifetime of the SDK
instance. A custom `SkyraStorage` controls its own persistence. Neither deletes
anything the service has already received.

## Sync

`widgetConfig()` puts the visitor ID, the traits and the stored state into the page
the app loads in its web view, where every script on that page can read them.

`sync` merges a state the app passes in with the stored one. The app passes entries
for what the visitor did, or the web widget's copy when it shows Skyra in a web view.
The SDK does not read cookies or web storage itself; the widget posts what it saves
to the app, and the app hands it over. After a sync with the widget both sides
can share one visitor ID, which links the visitor's web view activity and app
activity for Skyra.

## App privacy disclosures

The package bundles `PrivacyInfo.xcprivacy`, which declares UserDefaults
required-reason API use with reason `CA92.1`. The manifest is at
`Sources/Skyra/PrivacyInfo.xcprivacy` and is copied as a package resource. It also
declares no tracking, no tracking domains, and one collected data type: a device ID
(the visitor ID), used for analytics, not linked to the user's identity and not used
for tracking.

The decision request also carries traits, locale, time zone and device class. Skyra
uses them to decide which surveys to show. A trait that identifies a person, such as
an account ID, links the visitor ID to that person for your app, and your own
disclosures must say so. They must also account for your survey questions, the other
traits you supply, and how you use responses. The 400-day expiry on
the device says nothing about backend retention.

Source references: `Storage.swift`, `SkyraState.swift`, `DecisionService.swift`,
`BoundedTransport.swift` and `PrivacyInfo.xcprivacy` under `Sources/Skyra/`.
