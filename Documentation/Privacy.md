# Data and privacy

What the SDK stores and sends. The survey itself is shown, and its answers are sent,
by the Skyra widget in your web view; that is not covered here.

## What is sent

One request, `POST https://ingest.skyra.no/v1/decide`, each time the app calls
`getSurveys`:

| Data | Source |
| --- | --- |
| Organisation | The configuration. |
| Device class | `mobile` or `tablet`. |
| App language | The configured `language`, if set. |
| Device language | The device's first preferred language, such as `nb-NO`. |
| Time zone | The device's time zone, such as `Europe/Oslo`. |
| Traits | `channel: app`, plus the traits the app passes. The SDK collects none itself. |
| Visitor ID | A ULID the SDK creates on first use. |
| Survey states | For each stored survey: its state, the time of that state and its session ID. |
| `User-Agent` | The SDK version, the app's name and version, and the OS version. |
| `Accept-Language` | The device's preferred languages, added by iOS. |

The request uses no cache, cookies or credentials, doesn't follow redirects, and like
any request exposes the device's IP address to the service.

## What is stored

App-local UserDefaults under the `no.skyra.sdk` prefix, one value per organisation:

- the visitor ID;
- for each survey, its last state (`Selected`, `Capture`, `Completed` or `Rejected`),
  the time of that state and its session ID;
- for a survey in progress, the widget's progress: which question the visitor is on
  and the options chosen so far.

No written answers, traits or survey definitions are stored. Progress isn't sent with
`getSurveys`; it goes only to the widget in your page. UserDefaults isn't encrypted by the SDK.

A survey entry is dropped 400 days after it last changed. At most 200 entries and
1 MB of progress are kept, oldest dropped first. Old entries are removed the next time
the state is read or written. The visitor ID doesn't expire; it goes when the app's
storage is cleared, for example when the app is deleted.

`getSurveys` and `state()` create the visitor ID. Survey entries are written only by
`sync`. `.ephemeral` persistence keeps everything in memory for the life of the
instance.

Clearing the storage or using `.ephemeral` only affects the device. It doesn't delete
anything Skyra has already received.

## The web view

`widgetConfig()` puts the visitor ID, the traits and the stored state into your page,
where any script on the page can read them. The widget posts what it saves to the
app, which passes it to `sync`; the SDK reads no cookies or web storage itself. The
widget and the app then share one visitor ID, so Skyra sees the visitor's web view
and app activity as one visitor.

## App privacy disclosures

The bundled `PrivacyInfo.xcprivacy` declares:

- UserDefaults use with reason `CA92.1`;
- no tracking and no tracking domains;
- one collected data type: a device ID (the visitor ID), for analytics, not linked to
  the user's identity and not used for tracking.

Your own disclosures must cover the traits you send, your survey questions and how you
use the answers. A trait that identifies a person, such as an account ID, links the
visitor ID to that person, and your disclosures must say so.
