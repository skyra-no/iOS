# Skyra iOS SDK

Skyra displays hosted surveys in a floating popup inside an iOS app. Choose
screen-scoped presentation or explicitly triggered, installation-owned following
presentation. A unified, request-scoped decision can select and qualify a survey
before any screen-priority handoff.

**Unreleased iOS beta.** Repository access is currently restricted and no version
has been released. This repository
contains the Swift SDK, not the hosted JavaScript renderer. No Android support is claimed here.

## Install and integrate

**[Installation guide](Documentation/Installation.md)**

The guide covers Xcode package installation, complete SwiftUI and UIKit examples,
results, styling, and troubleshooting.

- iOS 15+, Swift 5.9+, Xcode 15.0.1+; Swift 5 language mode.
- Product and module: **Skyra**.
- No third-party package dependencies. The only bundled resource is the native
  required-reason API privacy manifest.
- macOS supports portable package tests; presentation is iOS-only.

Package URL: `https://github.com/skyra-no/iOS`. There is no released
version yet; confirm repository availability and any required access with Skyra. In
Xcode, choose **Branch** and enter `main`, or choose **Revision** and enter the exact
commit ID supplied by Skyra. Record the resolved revision; a branch can change between
resolutions.

### SwiftUI: root and explicit trigger

```swift
import Skyra
import SwiftUI

// Inside WindowGroup, above tabs/navigation:
AppTabView()
    .skyra(configuration: .init(organization: "organisation"))

struct FeedbackButton: View {
    @Environment(\.skyraInstallation) private var skyra

    var body: some View {
        Button("Give feedback") {
            skyra?.presentSurvey() // select from the configured organisation
        }
    }
}
```

The root `.skyra(configuration:)` installs one window-owned instance and makes its
installation available to descendant views. `presentSurvey()` uses the configured
survey decision; `presentSurvey(slug:)` requests that exact survey through the same
decision and native eligibility flow. A
following request is not tied to the trigger view's lifetime. Use `.skyraSurvey()`
or `.skyraSurvey("organisation/feedback")` for screen-scoped behavior that ends when
that screen leaves.

### UIKit: window and explicit trigger

```swift
import Skyra
import UIKit

// Follow-mode UIKit apps wrap their existing root before installing Skyra.
let existingRoot = window.rootViewController!
window.rootViewController = SkyraRootViewController(content: existingRoot)
let skyra = Skyra.install(in: window, configuration: .init(organization: "organisation"))

// In response to an app event or user action:
skyra.presentSurvey() // or skyra.presentSurvey(slug: "organisation/feedback")
```

Retain the returned installation for triggering, and retain `existingRoot` rather
than casting `window.rootViewController` to your former navigation-controller type.
This explicit wrapper step is required for UIKit following presentation. For
screen-scoped UIKit presentation, the wrapper is not needed; use the
`skyraSurvey(...)` controller attachment instead. See the
[installation guide](Documentation/Installation.md#explicit-following-presentation) for
complete examples and lifecycle details.

`SkyraDefaults` centralizes the production hosted and delivery origins. The
[installation guide](Documentation/Installation.md) includes custom-origin and
localhost HTTP configuration for development environments.

### Screen-scoped presentation

Attach once to each participating screen. Leaving cancels its pending request or
interrupts its unfinished popup without rejection. Omit the slug to let the configured
decision select; supply a slug to request that exact survey through the configured
decision. The same decision flow applies to screen requests.

Use the [complete examples](Documentation/Installation.md) for ownership and error
handling. Each screen makes its own request; leaving interrupts without rejection.
By default, an omitted slug selects the first returned App survey for the configured
organization. An explicit slug bypasses candidate-list selection, not the configured
decision or native eligibility.

## Survey behavior

Under the default decision, before creating a popup, the SDK checks delivered availability, App render type,
nonempty cards, capture percentage, and native completion/rejection history. New
eligible attempts honor the configured initial display delay; valid saved Capture
progress skips it. The dashboard labels these surveys **iOS · Beta**; the delivery
contract continues to use `renderType: App`.

By default, Skyra selects a candidate when needed and applies delivery availability,
capture, native history/cooldown, and initial-delay policy as one request decision.
The new `SkyraConfiguration.surveyDecision` closure replaces that complete business
decision. Its `SkyraSurveyDecisionContext` exposes the organization and requested
slug, plus `defaultDecision()` to reuse Skyra's default selection and eligibility
implementation. That default operation is memoized per request. This is the single
decision API for screen and following requests. No remote decision endpoint or
transport is included. See the installation guide for screen-priority behavior.

```swift
let configuration = SkyraConfiguration(
    organization: "organisation",
    surveyDecision: { context in
        try await context.defaultDecision()
    }
)
```

Screen-owned surveys can preempt a following survey only when
ready to display; when the screen visit ends, the existing following host resumes.
These decision and priority behaviors are beta features.

| Outcome | Meaning |
| --- | --- |
| `.notShown(reason: ...)` | No survey was selected or the request was suppressed by availability, capture, or cooldown rules. |
| `.completed` | The hosted page confirmed final answer acceptance. Later navigation or Close cannot downgrade it. |
| `.rejected` | The person deliberately closed an unfinished popup, or the app called `dismissSurvey()`. Active progress is cleared. |
| `.interrupted` | Screen departure, following-request cancellation, or host lifecycle ended an unfinished presentation. Saved progress is preserved. |
| `.unavailable` / `.failure(code)` | The hosted page became unavailable or failed after preflight. |

Direct async requests throw `CancellationError` when cancelled while waiting for
presenter readiness, selection, delivery, or initial delay, without recording
rejection. Screen attachments suppress preparation cancellation. Once presentation
has begun, interruption returns `.interrupted` (or `.completed` if acceptance was
already confirmed); attachments report the result through `onOutcome`. Configuration,
selection transport, storage, and other preparation failures throw errors. Ordinary
competing requests report `alreadyPresenting` (through `onError` for following
requests). A screen request may prepare alongside a following survey and take
priority when ready, as described above.

The popup is a child view, not an iOS modal sheet. The surrounding app is not dimmed.
The hosted page owns the survey theme, fonts, controls, and thank-you timing; Swift
owns its frame, keyboard/safe-area constraints, and Dynamic Type scale. While editing,
the first tap outside the popup may dismiss the keyboard before a subsequent tap
activates the app control.

## Storage and privacy

- Native storage is authoritative. The hosted page receives identity and supported
  saved progress during initialization; WKWebView uses a nonpersistent data store.
- Default storage persists across app launches. Visitor and survey records expire
  after 365 days from their relevant allocation/update; reads do not renew expiry.
- `.ephemeral` storage lasts for the SDK instance. A custom `SkyraStorage` must
  implement atomic `update` transactions and propagate failures.
- Restoration can recover question position and allowed selections, but **typed
  free text, recruitment values, traits, and survey definitions are not persisted
  natively**. The hosted page sends entered answers to Skyra.
- Completion and rejection histories enforce their respective cooldowns. `.fresh`
  requests a new session but does not bypass eligibility.

See [data and privacy](Documentation/Privacy.md) and the
package's `Sources/Skyra/PrivacyInfo.xcprivacy` manifest.

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

Automatic PR and main-branch CI runs formatting and package-contract checks on Linux.
Expensive Xcode builds and simulator tests are manual-only: use
**Actions → Swift Package → Run workflow** and select
the branch to validate. The manual matrix uses macOS 15 with Xcode 16.4 and 26.3; an
automatic green PR does not imply that simulator tests ran. Superseded runs are
cancelled automatically.

The hosted Xcode matrix no longer executes the declared minimum Xcode 15.0.1 / Swift
5.9 toolchain. The public requirements remain unchanged. Test success on these
simulators does not establish execution on iOS 15.

Live demo apps and their artifacts are maintained separately from this SDK checkout.

Documentation is maintained directly in Markdown under `Documentation/`.

## Support and contributions

Report SDK bugs and integration questions through
[GitHub Issues](https://github.com/skyra-no/iOS/issues).
Include the SDK revision, Xcode/iOS versions, integration style, steps to reproduce,
and relevant result/error codes. Remove personal data and credentials from logs.
See [contributing](CONTRIBUTING.md) for development and review expectations.

## License

[MIT](LICENSE) · Copyright (c) 2026 Skyra.
