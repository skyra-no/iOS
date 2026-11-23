# Use Skyra in an iOS app

The Skyra package stores a visitor's survey state, asks Skyra which surveys to show in
the app, and merges in what the visitor did with them. It shows no UI: how you show a
survey is up to you. Step 6 shows one way, the Skyra widget in your own web view.

## What you need

- Xcode 16.0+ and an app supporting iOS 15+.
- If the SDK repository is private, access from your GitHub account in Xcode.
- Your organisation's identifier in Skyra.
- A published inline survey with no URL rules and an Include audience rule on the
  trait `channel` equal to `app`. The SDK sends that trait with every request and your
  website does not, so the survey shows in the app only.
- To show surveys with the Skyra widget in a web view (step 6), as in the example: the
  `widget-store` feature switched on for your
  organisation by Skyra. Without that feature the widget keeps state in cookies, so the
  app never learns what the visitor did: a finished survey comes back, and progress is
  lost when the web view closes.
- The `app-surveys` feature switched on for your organisation by Skyra. It lets you set
  a retake and retrigger time on app surveys, and Skyra applies them. Without it, a
  finished survey comes back on the next call.

This is a beta; confirm
repository availability and any required package access with Skyra.

## 1. Install the package

1. In Xcode, choose **File → Add Package Dependencies…**.
2. Enter the package URL: `https://github.com/skyra-no/iOS`.
3. Choose **Up to Next Minor Version** and enter `0.1.0`.
4. Add the **Skyra** product to your app target.
5. Add `import Skyra` where you use it, then build the app.

## 2. Create one instance

```swift
import Skyra

let skyra = try Skyra(configuration: .init(
    organization: "acme",
    language: "nb",
    traits: ["plan": "premium"]
))
```

Create it once, for example at app start, and keep it. It is safe to use from any
thread. Creating it makes no request and stores nothing.

| Setting | Meaning |
| --- | --- |
| `organization` | Your organisation's identifier in Skyra. Required. |
| `language` | The language your app shows its content in, such as `nb`, `en` or `en-GB`. The device's own language setting is sent separately. |
| `traits` | Traits that hold for the whole app session, such as `plan`. At most 49. Names are trait slugs as in Skyra (letters, digits, `_` and `-`), and values are up to 256 characters. `channel` is always `app`. |
| `persistence` | `.persistent` (default) keeps the state in UserDefaults. `.ephemeral` keeps it in memory until the instance goes away. |
| `decisionOrigin` | The decision service. Change it only for a test environment. |

`Skyra(configuration:)` throws `SkyraError.invalidConfiguration` when a setting is
not usable.

To keep the state somewhere other than standard UserDefaults, pass a storage:

```swift
let shared = UserDefaults(suiteName: "group.com.acme.app")!
let skyra = try Skyra(
    configuration: .init(organization: "acme"),
    storage: SkyraUserDefaultsStorage(defaults: shared)
)
```

You can also implement `SkyraStorage` yourself. Its one method must read, transform
and write a value atomically, and must throw when it cannot. `SkyraUserDefaultsStorage`
does this within one process: an app and an extension sharing a suite can overwrite
each other's changes.

## 3. Ask which surveys to show

```swift
do {
    let surveys = try await skyra.getSurveys(traits: ["screen": "checkout"])
    for survey in surveys {
        // survey.slug, survey.language
    }
} catch {
    // Show nothing.
}
```

The call returns the surveys Skyra allows in the app right now, as Skyra gives them.
Skyra decides from the stored state, so a finished or closed survey comes back only
after the survey's own retake or retrigger time. An empty list means there is nothing
to show. Your app chooses where and when each survey shows.

Traits passed here describe this moment. They are added to the configured traits and
win when both name the same trait. Screens are traits, so a survey aimed at the
checkout screen is returned when you pass `["screen": "checkout"]` and the survey's
audience rules ask for it.

Call it when the screen or a trait changes. The request gives up after 1.5 seconds
and is never retried, so a slow network means no survey this time.

The answer names each survey by its slug and the language Skyra chose for it. It
does not contain the questions. The widget in step 6 loads the survey, runs its session
and sends the answers.

## 4. Store what the visitor did

Skip this step if the widget shows your surveys: step 6 stores every change for you.

`sync` is the one call that writes state. If you render a survey yourself, store each
step when it happens:

```swift
let visitor = try skyra.state().visitorId
let now = Int64(Date().timeIntervalSince1970 * 1000)

try skyra.sync(SkyraState(visitorId: visitor, surveys: [
    survey.slug: .init(state: .completed, lastSync: now, sessionId: sessionId),
]))
```

| State | When to store it | What Skyra does next |
| --- | --- | --- |
| `.selected` | You showed the survey. | Keeps returning the survey while it is allowed. |
| `.capture` | The visitor started answering. | Keeps returning the survey while it is allowed. |
| `.completed` | The visitor finished. | Leaves the survey out until its retake time has passed. |
| `.rejected` | The visitor closed it unfinished. | Leaves the survey out until its retrigger time has passed. |

If `.completed` is never stored, the survey keeps coming back.

`lastSync` is the Unix time of the state in milliseconds. `sessionId` is the
survey session's ID, a ULID. An entry
with an unusable session ID, a slug of another organisation, or a time more than a
year old is ignored.

`sync` merges, so you pass only the entries that changed. The entry with the later
`lastSync` replaces the stored one. That includes `.rejected` after `.completed`, so
do not store a close for a survey the visitor already finished.

## 5. Read the state

```swift
let state = try skyra.state()
state.visitorId                          // a ULID
state.surveys["acme/feedback"]?.state    // .selected, .capture, .completed, .rejected
state.surveys["acme/feedback"]?.sessionId
```

The first call creates the visitor ID.

A survey entry is dropped 400 days after its state last changed. The visitor ID is
kept until the storage is cleared. If the storage is lost, the visitor gets a new ID
and is treated as new.

## 6. Example: show a survey in a web view

This is one way to show a survey. If you show surveys another way, store what the
visitor did with `sync` as in step 4, and skip this step.

To show a survey in your own `WKWebView`, write a page that loads the Skyra widget and
places `<skyra-survey>` with the slug from step 3. `widgetConfig` gives you the widget's
configuration, filled in:

```swift
let html = """
<body>
<script>\(try skyra.widgetConfig())</script>
<script src="https://survey.skyra.no/skyra-survey.js"></script>
<skyra-survey slug="\(survey.slug)"></skyra-survey>
"""

let configuration = WKWebViewConfiguration()
configuration.userContentController.add(handler, name: Skyra.messageHandlerName)
let webView = WKWebView(frame: .zero, configuration: configuration)
webView.loadHTMLString(html, baseURL: URL(string: "https://acme.com")!)
```

It sets the organisation, the traits your latest `getSurveys` call sent, and a store
holding this visitor's state, so the widget is the same visitor as the app and keeps
nothing in cookies.

The widget posts everything it saves to the `skyra` message handler. Merge each message
into the stored state:

```swift
func userContentController(
    _ controller: WKUserContentController,
    didReceive message: WKScriptMessage
) {
    guard message.frameInfo.isMainFrame,
          let state = try? SkyraState(widget: message.body) else { return }
    _ = try? skyra.sync(state)
}
```

Take messages from the main frame only, as above, so an embedded frame cannot write
state. Pass an https `baseURL`: the widget does not ask Skyra from a `file:`,
`about:` or custom-scheme page. The widget hands state to the app only when Skyra has
switched on the `widget-store` feature for your organisation. The content controller keeps its handler alive, so remove it
with `removeScriptMessageHandler(forName:)` when the web view goes away.

What the widget saves has two parts, both stored and handed back:

- `state`: the visitor ID and each survey's state.
- `progress`: for a survey the visitor is part-way through, where they are in it.

A survey with progress is stored as `Capture`. When the visitor finishes or closes it,
the widget clears the progress and saves `Completed` or `Rejected`. A visitor who
leaves half-way continues at the same question in the same session the next time you
open the web view. Because every change is stored as it arrives, there is nothing to
fetch when the web view closes.

`SkyraState(widget:)` reads that object. To exchange state with something other than
the widget, `SkyraState(jsonObject:)` and `SkyraState(json:)` read this shape:

```json
{
  "visitorId": "01JD8ZQ6K3Y7M2N4P5R6S7T8V9",
  "surveys": {
    "acme/feedback": { "state": "Completed", "lastSync": 1794832273590, "sessionId": "01JD8ZR1M4XQ2B7C9D0E1F2G3H" }
  }
}
```

`sync` merges with these rules:

- The visitor ID that was created first is kept.
- For each survey, the entry with the later `lastSync` wins.
- When the times are equal, the state that is further along wins: `Selected`, then
  `Capture`, then `Rejected`, then `Completed`.
- Surveys of other organisations, entries older than 400 days and entries dated more than
  five minutes ahead are ignored.
- A visitor ID dated in the future is refused with `SkyraError.invalidState`.
- At most 200 surveys are kept, the latest first, and at most 1 MB of progress. When
  there is more, the oldest goes first.
- A survey entry that is malformed, has no `lastSync`, or is in a state the SDK does
  not store, is left out.

Syncing the same state twice changes nothing, so it is safe to sync on every message.

## Errors

| Error | Meaning |
| --- | --- |
| `SkyraError.invalidConfiguration` | The organisation, service address, language or configured traits are not usable. |
| `SkyraError.invalidTraits` | A trait passed to `getSurveys` has a name that is not a slug or a value that is too long, or there are too many. |
| `SkyraError.invalidState` | The state passed to `sync` is not readable or has no valid visitor ID. |
| `SkyraError.storageFailure` | The state could not be read or written. |
| `SkyraError.requestTooLarge` | The decision request would exceed the service's 64 KB limit. Send fewer or shorter traits. |
| `SkyraError.decisionHTTPStatus(code)` | The decision service answered with this status. 404 means it does not know the organisation. |
| `SkyraError.invalidDecisionResponse` | The decision service's answer could not be understood. |

`getSurveys` can also throw `URLError`, for example on a timeout, and
`CancellationError` when its task is cancelled. Treat every error from `getSurveys`
as "show nothing".

## Test environments and localhost

The SDK uses `https://ingest.skyra.no` for decisions and needs no address
configuration. If Skyra supplied a test environment, pass its origin:

```swift
let configuration = SkyraConfiguration(
    organization: "acme",
    decisionOrigin: URL(string: "http://localhost:3212")!
)
```

Use the origin only, without a path. HTTP is accepted only for `localhost`,
`127.0.0.1` and `::1`; other hosts require HTTPS.

For HTTP localhost testing, open the app target's **Info** tab. Add **App Transport
Security Settings** as a dictionary, then **Allow Local Networking** as Boolean
**YES** inside it. The raw keys are `NSAppTransportSecurity` and
`NSAllowsLocalNetworking`. Add to any existing dictionary and keep its other entries.

Use the iOS Simulator for localhost, because it reaches services on your Mac. A
physical iPhone's localhost is the phone itself.

## If no survey comes back

- Check that the survey is published as an inline survey with an audience rule on
  `channel` equal to `app`.
- Check that the survey has no URL rules, and that the traits you pass match its
  audience rules, including the screen.
- Print `try skyra.state()`. A survey in `Completed` or `Rejected` is left out until
  its retake or retrigger time has passed. Use `.ephemeral`
  persistence while testing to start from an empty state on each launch.
- A `decisionHTTPStatus(404)` error means the organisation identifier is wrong.
- A `URLError` timeout means the service did not answer within 1.5 seconds.
