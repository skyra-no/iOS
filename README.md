# Skyra iOS SDK

Shows Skyra surveys in an iOS app. The SDK keeps the visitor's survey state on the
device, asks Skyra which surveys to show, and stores what the visitor did with them.
Surveys are shown by the Skyra widget in your own web view. Beta, iOS only.

## Requirements

- iOS 15+, Xcode 16.0+, Swift 5 language mode.
- No dependencies. The package bundles a privacy manifest.
- Three features switched on for your organisation. See
  [what you need](Documentation/Installation.md#what-you-need).

## Install

Add `https://github.com/skyra-no/iOS` in Xcode with **Up to Next Minor Version** from
`0.2.0`, and add the **Skyra** product to your app target. Until 1.0, a minor version
can change the API and a patch version can't. See the [changelog](CHANGELOG.md).

## Quick start

```swift
import Skyra

// Create one instance and keep it.
let skyra = try Skyra(configuration: .init(organization: "acme", language: "nb"))

// Ask when the screen or a trait changes.
let surveys = try await skyra.getSurveys(traits: ["screen": "checkout"])

// Show surveys.first in a web view: a page with skyra.widgetConfig() and
// <skyra-survey>, and skyra.messageHandler to store what the survey reports.
```

The [integration guide](Documentation/Installation.md) explains who does what, each
step, the web view and errors. Merge rules and the JSON shape are in the [reference](Documentation/Reference.md).

## Privacy

The SDK stores a visitor ID, survey states, times and session IDs, and the widget's
progress for a survey in progress. It sends the visitor ID and survey states to Skyra
with each request. See [data and privacy](Documentation/Privacy.md).

## Support

Skyra maintains this SDK and doesn't take pull requests. Report bugs and questions in
[GitHub Issues](https://github.com/skyra-no/iOS/issues) or at support@skyra.no, with
`Skyra.version`, the Xcode and iOS versions, steps to reproduce and the error. Remove
personal data from logs.

## License

[MIT](LICENSE) · Copyright (c) 2026 Skyra.
