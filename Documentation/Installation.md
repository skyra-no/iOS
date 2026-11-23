# Use Skyra surveys in an iOS app

## How it works

**Skyra** decides which survey a visitor sees and when it may come back, and runs the
survey itself: the questions, the answers and sending them to Skyra. The survey runs
in a web view, the same way it does on a website.

**The SDK** remembers what each visitor did with each survey, asks Skyra which
survey to show, and stores what the survey reports from the web view.

**You** add the SDK, ask for a survey when the screen changes, and show the survey
you get in a web view, using the page and handler the SDK gives you.

## What you need

From Skyra (ask at support@skyra.no):

- your organisation's identifier;
- the `app-surveys` and `widget-store` features switched on for your organisation.
  `app-surveys` keeps a finished survey away until its retake time has passed.
  `widget-store` lets the survey in the web view report back to the app.

In the Skyra dashboard:

- **Audience targeting** switched on by an organisation admin under
  **Settings → General → Early access · Organisation**;
- a published inline survey with no URL rules and the audience rule **Include if
  `channel` equals `app`**. Only the app sends that trait, so the survey never shows
  on your website.

In your project: Xcode 16.0+ and an app supporting iOS 15+.

## 1. Add the SDK

1. In Xcode, choose **File → Add Package Dependencies…**.
2. Enter `https://github.com/skyra-no/iOS`.
3. Choose **Up to Next Minor Version** and enter `0.2.0`.
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
| `persistence` | `.persistent` (default) keeps what visitors did in UserDefaults; `.ephemeral` keeps it in memory. |

To keep it somewhere else, see [custom storage](Reference.md#custom-storage).

## 3. Ask for a survey

Call `getSurveys` when the screen or a trait changes:

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

Show the first survey; one the visitor has started always comes first. An empty list,
or an error, means show nothing.

The traits you pass are added to the configured ones for this call. Screens are
traits: a survey aimed at the checkout screen comes back when you pass
`["screen": "checkout"]`. The request gives up after 1.5 seconds and isn't retried,
so a slow network means no survey this time.

## 4. Show the survey in a web view

The survey runs inside the web view, so the app can't see what the visitor does
there. The SDK gives you two things to connect them: a page that loads the survey,
and a handler that receives what the survey reports and stores it.

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
configuration.userContentController.add(skyra.messageHandler, name: Skyra.messageHandlerName)
let webView = WKWebView(frame: .zero, configuration: configuration)
webView.loadHTMLString(html, baseURL: URL(string: "https://app.acme.com")!)
```

- `widgetConfig()` tells the survey your organisation, your traits, and where to
  report: to the app instead of cookies.
- `skyra.messageHandler` receives every report, for example "started", "on question
  2" or "finished", and stores it. That's how the next `getSurveys` knows a survey
  was finished. It ignores reports from frames embedded in your page.
- `<html lang>` makes the survey use the language Skyra chose.
- Use an `https` `baseURL`. The host doesn't have to exist; nothing is loaded from it.
- When the web view goes away, call
  `configuration.userContentController.removeScriptMessageHandler(forName: Skyra.messageHandlerName)`.

Everything is stored as it happens, so there's nothing to do when the web view
closes. A visitor who leaves halfway continues at the same question next time.

### Closing the web view when the survey ends

The survey doesn't close the web view itself. To hear when a survey changes, for
example to close the web view when it's finished, implement `SkyraSurveyListener` and
pass it to the handler. It's called after the change is stored:

```swift
final class SurveyViewController: UIViewController, SkyraSurveyListener {
    func surveyDidChange(_ slug: String, to state: SkyraState.Status) {
        if state == .completed || state == .rejected {
            dismiss(animated: true)
        }
    }
}

// Where you set up the web view:
configuration.userContentController.add(
    skyra.messageHandler(listener: self),
    name: Skyra.messageHandlerName
)
```

The handler holds the listener weakly, so the view controller can be its own
listener.

## What the SDK remembers

For each survey, the SDK keeps the visitor's last step:

| State | Set when | Effect on the next `getSurveys` |
| --- | --- | --- |
| `Selected` | The survey was shown. | Still returned. |
| `Capture` | The visitor started answering. | Still returned, first. |
| `Completed` | The visitor finished. | Left out until the survey's retake time has passed. |
| `Rejected` | The visitor closed it unfinished. | Left out until the survey's retrigger time has passed. |

Retake and retrigger times are set on the survey in Skyra, so you can change them
without an app update. A survey's entry is dropped 400 days after it last changed.
Merge rules and the stored format are in the [reference](Reference.md).

## Errors

| Error | Meaning |
| --- | --- |
| `SkyraError.invalidConfiguration` | A setting is not usable. Traits: at most 49, names of letters, digits, `_` and `-`, values up to 256 characters. |
| `SkyraError.invalidTraits` | A trait passed to `getSurveys` breaks the same rules, or configured and passed traits together exceed 49. |
| `SkyraError.invalidState` | What was stored or passed in is not readable or has no valid visitor ID. |
| `SkyraError.storageFailure` | The state could not be read or written. |
| `SkyraError.requestTooLarge` | The request would exceed the service's 64 KB limit. Send fewer or shorter traits. |
| `SkyraError.decisionHTTPStatus(code)` | Skyra answered with this status. 404 means it doesn't know the organisation. |
| `SkyraError.invalidDecisionResponse` | Skyra's answer could not be understood. |

`getSurveys` can also throw `URLError`, for example on a timeout, and
`CancellationError` when its task is cancelled.

## Troubleshooting

**No survey comes back.**
- Check the survey: published, inline, no URL rules, Include if `channel` equals
  `app`, and the traits you pass match its other audience rules, including the screen.
- Check that Audience targeting is on, or the `channel` rule isn't saved.
- `print(try skyra.state())`. A `Completed` or `Rejected` survey is left out until its
  retake or retrigger time has passed. Use `.ephemeral` persistence while testing to
  start empty on each launch.
- `decisionHTTPStatus(404)`: the organisation identifier is wrong.
- `URLError` timeout: Skyra didn't answer within 1.5 seconds.

**A finished survey comes back straight away.** `app-surveys` isn't switched on.

**Progress is lost, or `skyra.state()` stays empty after answering.** `widget-store`
isn't switched on, or `skyra.messageHandler` isn't registered under
`Skyra.messageHandlerName`.
