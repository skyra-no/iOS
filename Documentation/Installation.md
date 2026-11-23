# Use Skyra surveys in an iOS app

The SDK keeps the visitor's survey state on the device, asks Skyra which surveys to
show, and stores what the visitor did with them. It has no UI. Surveys are shown by
the Skyra widget in your own web view (step 4).

## What you need

- Xcode 16.0+ and an app supporting iOS 15+.
- Access to the `skyra-no/iOS` repository from your GitHub account in Xcode. Ask
  Skyra for it.
- Your organisation's identifier in Skyra.
- These features switched on for your organisation by Skyra:
  - **Audience targeting**, under Early access in the organisation settings, so you
    can add the `channel` rule below.
  - `app-surveys`. Skyra then applies the survey's retake and retrigger times in the
    app. Without it, a finished survey comes back on the next call.
  - `widget-store`. The widget then hands its state to the app. Without it, the widget
    keeps state in cookies: the app never learns what the visitor did, and progress is
    lost when the web view closes.
- A published inline survey with no URL rules and an Include audience rule on the
  trait `channel` equal to `app`. The SDK sends that trait with every request and your
  website doesn't, so the survey shows in the app only.

## 1. Install

1. In Xcode, choose **File → Add Package Dependencies…**.
2. Enter `https://github.com/skyra-no/iOS`.
3. Choose **Up to Next Minor Version** and enter `0.1.0`.
4. Add the **Skyra** product to your app target.

## 2. Create one instance

```swift
import Skyra

let skyra = try Skyra(configuration: .init(
    organization: "acme",
    language: "nb",
    traits: ["plan": "premium"]
))
```

Create it once, for example at app start, and keep it. It's safe to use from any
thread. Creating it makes no request and stores nothing.

| Setting | Meaning |
| --- | --- |
| `organization` | Your organisation's identifier in Skyra. Required. |
| `language` | The language your app shows its content in, such as `nb`, `en` or `en-GB`. The device's language is sent separately. |
| `traits` | Traits that hold for the whole session, such as `plan`. At most 49. Names are trait slugs (letters, digits, `_` and `-`); values are up to 256 characters. `channel` is always `app`. |
| `persistence` | `.persistent` (default) keeps the state in UserDefaults. `.ephemeral` keeps it in memory until the instance goes away. |
| `decisionOrigin` | The decision service. Change it only for a test environment. |

An unusable setting throws `SkyraError.invalidConfiguration`.

To keep the state in another UserDefaults suite, pass a storage:

```swift
let skyra = try Skyra(
    configuration: .init(organization: "acme"),
    storage: SkyraUserDefaultsStorage(defaults: UserDefaults(suiteName: "com.acme.skyra")!)
)
```

`SkyraUserDefaultsStorage` is safe within one process. Don't share its suite between
an app and an extension: they can overwrite each other's changes. You can also
implement `SkyraStorage` yourself; its one method must read, transform and write a
value atomically, and throw when it can't.

## 3. Ask which surveys to show

```swift
do {
    let surveys = try await skyra.getSurveys(traits: ["screen": "checkout"])
    // surveys[0].slug is "acme/feedback", surveys[0].language is "nb"
} catch {
    // Show nothing.
}
```

You get the surveys Skyra allows right now, in Skyra's order; the SDK doesn't filter
or reorder them. An empty list means there's nothing to show. Your app decides where
and when to show each one.

Traits passed here describe this moment and are added to the configured traits,
winning when both name the same trait. Screens are traits: a survey aimed at the
checkout screen comes back when you pass `["screen": "checkout"]`.

Call it when the screen or a trait changes, not in a loop. The request gives up after
1.5 seconds and isn't retried, so a slow network means no survey this time.

## 4. Show the survey in a web view

The answer names the survey and its language, not its questions. The Skyra widget
loads the survey, shows it and sends the answers, so you show it in your own
`WKWebView`:

```swift
let html = """
<!doctype html>
<html>
<head>
<meta name="viewport" content="width=device-width, initial-scale=1">
<script>\(try skyra.widgetConfig())</script>
<script src="https://survey.skyra.no/skyra-survey.js"></script>
</head>
<body>
<skyra-survey slug="\(survey.slug)"></skyra-survey>
</body>
</html>
"""

let configuration = WKWebViewConfiguration()
configuration.userContentController.add(handler, name: Skyra.messageHandlerName)
let webView = WKWebView(frame: .zero, configuration: configuration)
webView.loadHTMLString(html, baseURL: URL(string: "https://app.acme.com")!)
```

`widgetConfig()` gives the widget your organisation, the traits of your latest
`getSurveys` call, and this visitor's stored state. The widget is then the same
visitor as the app and keeps nothing in cookies.

The widget posts every change it saves to your handler. Pass each one to `sync`:

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

- Take messages from the main frame only, as above, so an embedded frame can't write
  state.
- Use an `https` `baseURL`. The host doesn't have to exist, since nothing is loaded
  from it. The widget doesn't run on `file:`, `about:` or custom-scheme pages.
- The content controller keeps its handler alive. Remove it with
  `removeScriptMessageHandler(forName:)` when the web view goes away.

Every change is stored as it arrives, so there's nothing to do when the web view
closes. A visitor who leaves halfway continues at the same question next time you
show the survey.

## 5. Read the state

```swift
let state = try skyra.state()
state.visitorId                          // a ULID
state.surveys["acme/feedback"]?.state    // .selected, .capture, .completed or .rejected
```

The first call creates the visitor ID. It's kept until the storage is cleared; after
that the visitor is treated as new.

## Reference: state and sync

Each survey entry holds a state, its time (`lastSync`, Unix milliseconds) and the
survey session's ID. A survey in progress also holds the widget's progress.

| State | Set when | Effect on the next `getSurveys` |
| --- | --- | --- |
| `Selected` | The survey was shown. | None. |
| `Capture` | The visitor started answering. | None. |
| `Completed` | The visitor finished. | Left out until the survey's retake time has passed. |
| `Rejected` | The visitor closed it unfinished. | Left out until the survey's retrigger time has passed. |

Skyra applies these effects, not the SDK.

`sync` is the only call that writes state. It merges, so you pass only what changed:

- The visitor ID that was created first is kept. One dated in the future throws
  `SkyraError.invalidState`.
- For each survey, the entry with the later `lastSync` wins. On equal times the state
  further along wins: `Selected`, `Capture`, `Rejected`, `Completed`.
- Entries for other organisations, entries more than 400 days old and entries dated
  more than five minutes ahead are ignored, as are malformed ones.
- Progress is kept only while a survey is `Capture`, at most 64 KB per survey and
  1 MB in total.
- At most 200 surveys are kept. Over a limit, the oldest goes first.

Syncing the same state twice changes nothing. A survey entry is dropped 400 days
after it last changed.

`SkyraState(json:)`, `SkyraState(jsonObject:)` and `json()` use this shape. A survey
in progress also carries a `progress` object:

```json
{
  "visitorId": "01JD8ZQ6K3Y7M2N4P5R6S7T8V9",
  "surveys": {
    "acme/feedback": { "state": "Completed", "lastSync": 1794832273590, "sessionId": "01JD8ZR1M4XQ2B7C9D0E1F2G3H" }
  }
}
```

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

The SDK uses `https://ingest.skyra.no` and needs no address configuration. If Skyra
gave you a test environment, pass its origin:

```swift
let configuration = SkyraConfiguration(
    organization: "acme",
    decisionOrigin: URL(string: "http://localhost:3212")!
)
```

Use the origin only, without a path. HTTP is accepted only for `localhost`,
`127.0.0.1` and `::1`.

For HTTP on localhost, add **App Transport Security Settings → Allow Local Networking
= YES** to the app target's **Info** tab (`NSAppTransportSecurity` /
`NSAllowsLocalNetworking`), keeping any existing entries. Use the Simulator: on a
physical iPhone, localhost is the phone itself.

## If no survey comes back

- Check that the survey is a published inline survey with no URL rules and an Include
  rule `channel` equal to `app`, and that the traits you pass match its other audience
  rules, including the screen.
- Check that Skyra has switched on `app-surveys` for your organisation. If a finished
  survey keeps coming back, that's the cause; if progress is lost or nothing is
  stored, check `widget-store`.
- Print `try skyra.state()`. A `Completed` or `Rejected` survey is left out until its
  retake or retrigger time has passed. Use `.ephemeral` persistence while testing to
  start empty on each launch.
- `decisionHTTPStatus(404)` means the organisation identifier is wrong.
- A `URLError` timeout means the service didn't answer within 1.5 seconds.
