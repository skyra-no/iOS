# Use Skyra surveys in an iOS app

The SDK keeps the visitor's survey state on the device, asks Skyra which surveys to
show, and stores what the visitor did with them. Surveys are shown by the Skyra
widget in your own web view.

## What you need

- Xcode 16.0+ and an app supporting iOS 15+.
- Access to the `skyra-no/iOS` repository from your GitHub account in Xcode. Ask
  Skyra at support@skyra.no.
- Your organisation's identifier in Skyra.
- **Audience targeting** switched on by an organisation admin under
  **Settings → General → Early access · Organisation**.
- `app-surveys` and `widget-store`, switched on for your organisation by Skyra (ask at
  support@skyra.no). With `app-surveys`, a finished survey stays away until its retake
  time has passed. With `widget-store`, the app learns what the visitor did in the web
  view.
- A published inline survey with no URL rules and the audience rule **Include if
  `channel` equals `app`**. Only the app sends that trait, so the survey never shows on
  your website.

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
thread.

| Setting | Meaning |
| --- | --- |
| `organization` | Your organisation's identifier in Skyra. Required. |
| `language` | The language your app shows its content in, such as `nb` or `en-GB`. |
| `traits` | Traits that hold for the whole session, such as `plan`. |
| `persistence` | `.persistent` (default) keeps the state in UserDefaults; `.ephemeral` keeps it in memory. |
| `decisionOrigin` | The decision service. Change it only for a test environment. |

To store the state elsewhere, pass `storage:` with a `SkyraUserDefaultsStorage` or
your own `SkyraStorage`. Don't share a UserDefaults suite between an app and an
extension.

## 3. Ask which surveys to show

```swift
let surveys: [SkyraSurvey]
do {
    surveys = try await skyra.getSurveys(traits: ["screen": "checkout"])
} catch {
    print("Skyra:", error)   // see Errors below
    surveys = []
}
guard let survey = surveys.first else { return }   // nothing to show
```

Show the first survey; a survey the visitor has started always comes first. Treat an
error like an empty list.

Traits you pass here are added to the configured ones, for this call only. Screens
are traits: a survey aimed at the checkout screen comes back when you pass
`["screen": "checkout"]`. Call `getSurveys` when the screen or a trait changes, not
in a loop. The request gives up after 1.5 seconds and isn't retried, so a slow
network means no survey this time.

## 4. Show the survey in a web view

Show the survey with the Skyra widget in a `WKWebView`, with `<html lang>` set to
`survey.language`:

```swift
let html = """
    <!doctype html>
    <html lang="\(survey.language)">
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

`widgetConfig()` gives the widget your organisation, your traits and the visitor's
stored state, so the widget and the app share one visitor ID. `handler` is your
`WKScriptMessageHandler`. It receives every change the widget saves; pass each one to
`sync`:

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
- Use an `https` `baseURL`. The host doesn't have to exist; nothing is loaded from it.
- Remove the handler with `removeScriptMessageHandler(forName:)` when the web view
  goes away; the content controller keeps it alive.

Every change is stored as it arrives. A visitor who leaves halfway continues at the
same question next time.

## Survey states

| State | Set when | Effect on the next `getSurveys` |
| --- | --- | --- |
| `Selected` | The survey was shown. | Still returned. |
| `Capture` | The visitor started answering. | Still returned, first. |
| `Completed` | The visitor finished. | Left out until the survey's retake time has passed. |
| `Rejected` | The visitor closed it unfinished. | Left out until the survey's retrigger time has passed. |

Retake and retrigger times are set on the survey in Skyra and applied there, so you
can change them without an app update. `sync` merges what the widget sends with what is
stored, and the latest change per survey wins. Entries are dropped 400 days after
they last changed. The details are in the [reference](Reference.md).

## Errors

| Error | Meaning |
| --- | --- |
| `SkyraError.invalidConfiguration` | A setting is not usable. Traits: at most 49, names of letters, digits, `_` and `-`, values up to 256 characters. |
| `SkyraError.invalidTraits` | A trait passed to `getSurveys` breaks the same rules, or configured and passed traits together exceed 49. |
| `SkyraError.invalidState` | The state passed to `sync` is not readable or has no valid visitor ID. |
| `SkyraError.storageFailure` | The state could not be read or written. |
| `SkyraError.requestTooLarge` | The request would exceed the service's 64 KB limit. Send fewer or shorter traits. |
| `SkyraError.decisionHTTPStatus(code)` | The decision service answered with this status. 404 means it does not know the organisation. |
| `SkyraError.invalidDecisionResponse` | The decision service's answer could not be understood. |

`getSurveys` can also throw `URLError`, for example on a timeout, and
`CancellationError` when its task is cancelled.

## Test environments and localhost

If Skyra gave you a test environment, pass its origin:

```swift
let configuration = SkyraConfiguration(
    organization: "acme",
    decisionOrigin: URL(string: "http://localhost:3212")!
)
```

Use the origin only, without a path. HTTP is accepted only for `localhost`,
`127.0.0.1` and `::1`. For HTTP on localhost, add **App Transport Security Settings →
Allow Local Networking = YES** to the app target's **Info** tab, and use the Simulator:
on a physical iPhone, localhost is the phone itself.

## If no survey comes back

- Check that the survey is a published inline survey with no URL rules and an Include
  rule `channel` equal to `app`, and that the traits you pass match its other audience
  rules, including the screen.
- Check that Audience targeting is on, so the `channel` rule is saved.
- `print(try skyra.state())`. A `Completed` or `Rejected` survey is left out until its
  retake or retrigger time has passed. Use `.ephemeral` persistence while testing to
  start empty on each launch.
- `decisionHTTPStatus(404)` means the organisation identifier is wrong.
- A `URLError` timeout means the service didn't answer within 1.5 seconds.

## If a finished survey comes back

`app-surveys` isn't switched on for your organisation.

## If state isn't saved

If progress is lost, or `skyra.state()` stays empty after the visitor answers,
`widget-store` isn't switched on, or your handler isn't registered under
`Skyra.messageHandlerName`.
