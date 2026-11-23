# Skyra iOS SDK

A Swift toolkit for using Skyra surveys in an iOS app. It does three things:

- stores the visitor's survey state on the device,
- asks Skyra's decision service which surveys the visitor may see in the app,
- merges new state into it, from the app or from the Skyra web widget in a web view.

It shows no UI: how you show a survey is up to you. One way, shown in the guide, is the
Skyra widget in your own web view, which the toolkit exchanges state with. That needs
the `widget-store` feature switched on for your organisation by Skyra.

A survey for the app is an inline survey with no URL rules and an Include audience rule
on the trait `channel` equal to `app`. The toolkit sends that trait with every request.

**iOS beta.** Repository access is currently restricted. No Android support is claimed here.

## Requirements

- iOS 15+, Swift 5.9+, Xcode 15.0.1+; Swift 5 language mode.
- Product and module: **Skyra**.
- No third-party package dependencies. The only bundled resource is the
  privacy manifest.
- macOS is supported so the package tests can run without a simulator.

Package URL: `https://github.com/skyra-no/iOS`. The current version is
`0.1.0`. In Xcode, choose **Up to Next Minor Version** and enter `0.1.0`. Until 1.0, a
new minor version (`0.2.0`) can change the API; a patch version (`0.1.1`) does not.
Changes are listed in the [changelog](CHANGELOG.md).

## Quick start

```swift
import Skyra

// Create one instance and keep it.
let skyra = try Skyra(configuration: .init(
    organization: "acme",
    language: "nb",
    traits: ["plan": "premium"]
))

// Ask when the screen or a trait changes.
let surveys = try await skyra.getSurveys(traits: ["screen": "checkout"])

for survey in surveys {
    // survey.slug is "acme/feedback", survey.language is "nb".
    // Show it however you like, for example with <skyra-survey slug="…"> in
    // your own web view, where skyra.widgetConfig() configures the widget.
}

// Store what the visitor did, here as reported by the widget.
// sync is the one call that writes state.
try skyra.sync(SkyraState(widget: message.body))
```

The [integration guide](Documentation/Installation.md) covers each step, errors, and
syncing with a web view.

## What the toolkit does

### Storage

Skyra keeps one visitor ID and one entry per survey: the last state, when it
happened, and the session it belongs to. The default backend is app-local
UserDefaults, one value per organisation. `.ephemeral` persistence keeps the state
in memory for the lifetime of the instance. Pass your own `SkyraStorage` to keep the
state somewhere else, such as an app group.

`skyra.state()` returns the whole state. A survey entry is dropped 400 days after its state last changed. The
visitor ID is kept until the storage is cleared.

### The decision call

`getSurveys(traits:)` sends the stored state, the traits, the
app's language, the device's language, the time zone and the device class to the
decision service. It returns the surveys the service allows, as the service gives them.
The service decides, using the stored state, so a finished or closed survey comes back
only after the survey's own retake or retrigger time. An empty list means there is
nothing to show.

Traits passed to the call are added to the configured traits and win when both name
the same trait. Screens are traits, so pass the current screen here. `channel: app` is
always sent and cannot be replaced.

The request gives up after 1.5 seconds and is never retried. The call records nothing
about the surveys it returns.

### Sync

`sync(_:)` is the one call that writes state. It merges a `SkyraState` into the
device's copy, stores the result and returns it. Use it for both jobs:

- to take in what the web widget reports from a web view,
- to store what the visitor did with a survey the app rendered itself.

```swift
// The page's store posts what the widget saves to a WKScriptMessageHandler.
let widgetState = try SkyraState(widget: message.body)
let merged = try skyra.sync(widgetState)
```

If you show a survey in a web view, `skyra.widgetConfig()` gives the page the
widget's configuration: the organisation, the traits, and a `store` holding this
visitor's state that posts every change back. See the
[web view example](Documentation/Installation.md#6-example-show-a-survey-in-a-web-view).

| State | Meaning | Effect on the next decision |
| --- | --- | --- |
| `Selected` | The survey was shown. | None. |
| `Capture` | The visitor is answering. | None. |
| `Completed` | The visitor finished. | Left out until the survey's retake time has passed. |
| `Rejected` | The visitor closed it unfinished. | Left out until the survey's retrigger time has passed. |

The decision service applies these. The toolkit returns its answer unchanged.

The merge rules:

- The visitor ID that was created first is kept, so both sides settle on one visitor.
- For each survey, the entry with the later time wins. When the times are equal, the
  state that is further along wins.
- Surveys of other organisations, entries older than 400 days and entries dated more than
  five minutes ahead are ignored.
- At most 200 surveys are kept, the latest first, and at most 1 MB of progress.

`SkyraState` reads and writes the decision contract's `skyraState` shape:

```json
{
  "visitorId": "01JD8ZQ6K3Y7M2N4P5R6S7T8V9",
  "surveys": {
    "acme/feedback": { "state": "Completed", "lastSync": 1794832273590, "sessionId": "01JD8ZR1M4XQ2B7C9D0E1F2G3H" }
  }
}
```

## Privacy

The stored state holds a visitor ID, survey states, times and session IDs, and the
widget's progress for a survey the visitor is part-way through in a web view. It never
holds written answers, traits or survey definitions. See
[data and privacy](Documentation/Privacy.md) and the package's
`Sources/Skyra/PrivacyInfo.xcprivacy` manifest.

## Development checks

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
bash Scripts/format-swift.sh --lint
bash Scripts/check-package.sh
swift build
swift test
xcodebuild -scheme Skyra -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath DerivedData build
xcodebuild -scheme Skyra -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath DerivedData test
```

Automatic PR and main-branch CI runs formatting and package-contract checks on Linux,
and builds and tests the package on macOS with the declared minimum Xcode 15.0.1 /
Swift 5.9 toolchain. Newer Xcode builds and simulator tests are manual: use
**Actions → Swift Package → Run workflow** and select the branch to validate. The
manual matrix uses macOS 15 with Xcode 16.4 and 26.3, so a green PR does not mean
simulator tests ran, and an iOS 15 runtime is not exercised.

## Support and contributions

Report SDK bugs and integration questions through
[GitHub Issues](https://github.com/skyra-no/iOS/issues). Include the SDK version (`Skyra.version`),
Xcode and iOS versions, steps to reproduce, and the error you got. Remove personal
data and credentials from logs. See [contributing](CONTRIBUTING.md) for development
and review expectations.

## License

[MIT](LICENSE) · Copyright (c) 2026 Skyra.
