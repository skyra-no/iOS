# Add Skyra surveys to an iOS app

Skyra shows a hosted survey in a floating popup over an existing screen. The rest
of the app stays interactive. Install Skyra at the window root, then choose
screen-scoped presentation or explicitly triggered following presentation. Both
use one request-scoped survey decision before eligibility and presentation priority
are resolved.

## What you need

- Xcode 15.0.1+, Swift 5.9+, and an app supporting iOS 15+.
- If the SDK repository is private, access from your GitHub account in Xcode.
- The **iOS surveys** beta enabled for your organisation. In the survey editor,
  select **iOS**, labelled **Beta · iOS apps**.
- A published iOS survey with questions. An exact slug such as
  `organisation/feedback` is optional when using organization-based selection.

For the first test, set capture to **100%** in Skyra. Otherwise a request may
correctly remain hidden. This is an unreleased beta; confirm repository availability
and any required package access with Skyra. Hosted iOS-beta enablement and a published
survey are separate service requirements.

## 1. Install the package

1. In Xcode, choose **File → Add Package Dependencies…**.
2. Enter the package URL: `https://github.com/skyra-no/iOS`.
3. Choose **Branch** and enter `main`, or choose **Revision** and enter the exact commit ID supplied by Skyra.
4. Add the **Skyra** product to your app target.
5. Add `import Skyra` in your integration files, then build the app.

Choose the SwiftUI or UIKit integration below. You do not need both for a screen.

## 2. SwiftUI: install at the root

Add `.skyra(configuration: .init(organization: "organisation"))` to your existing root view inside `WindowGroup`, above tabs and
navigation. Keep your existing environment objects and scene configuration. Do
not add another app declaration; adapt your existing one:

```swift
import Skyra
import SwiftUI

@main
struct YourApp: App {
    var body: some Scene {
        WindowGroup {
            AppTabView()
                .skyra(configuration: .init(organization: "organisation"))
        }
    }
}
```

Replace `AppTabView` with your app's existing root view. Skyra retains one instance
for that window, installs its presenter, and makes it available to descendant
screens. Intermediate views need no Skyra properties or arguments.

## 3. SwiftUI: attach a survey to a screen

On the existing screen's content, add `.skyraSurvey` with an exact slug, or omit
the slug to select for the configured organization:

```swift
import Skyra
import SwiftUI

struct CheckoutView: View {
    var body: some View {
        Form {
            Text("Your existing checkout content")
        }
        .skyraSurvey() // or .skyraSurvey("organisation/feedback")
    }
}
```

Keep your real checkout content in place of the example form. Entering the screen
requests a survey. An explicit slug is supplied to the configured decision; an
omitted slug lets the decision select. Leaving cancels the request or interrupts its
unfinished popup. Skyra resolves the decision, eligibility, and display delay; do not
add a timer or survey-launch button. `.skyraSurvey("organisation/feedback")` keeps
the explicit-slug behavior.

### Optional results and errors

The basic integration requires no callbacks. Add them when the app needs outcomes
or diagnostics:

```swift
checkoutContent
    .skyraSurvey(
        "organisation/feedback",
        onOutcome: { result in print("Skyra: \(result)") },
        onError: { error in print("Skyra request failed: \(error)") }
    )
```

To handle invalid startup configuration, use `.skyra(onError: { error in ... })`
at the root. Initialization failure leaves your app visible and usable. Integration
errors are also logged in debug builds. Configuration and the root callback are
captured for that root's lifetime; install a new root to change them.

## Explicit following presentation

Use this opt-in mode when an app event or user action should request a survey that
is not owned by the view that triggered it. Keep `.skyra(configuration:)` at the window root, then
read its installation from the environment and trigger it explicitly:

```swift
import Skyra
import SwiftUI

struct FeedbackButton: View {
    @Environment(\.skyraInstallation) private var skyra

    var body: some View {
        Button("Give feedback") {
            skyra?.presentSurvey(
                slug: nil, // omit or pass nil to select; supply a slug for an exact survey
                onOutcome: { result in print("Skyra: \(result)") },
                onError: { error in print("Skyra request failed: \(error)") }
            )
        }
    }
}
```

`presentSurvey` returns a `SkyraSurveyRequest` immediately; it does not throw or
wait for presentation. Preparation failures go to `onError` (and are logged in debug
builds). Retain the handle only if you need to call `cancel()`; dropping it does not
cancel the request. Cancellation interrupts without rejection, including before
display, and reports `.interrupted` through `onOutcome`. In contrast,
`skyraInstallation.dismissSurvey()` deliberately rejects a displayed unfinished
survey. Confirmed completion takes precedence over either action.

UIKit following presentation requires a new root-host step. Wrap your existing root
before installing Skyra, then use the returned installation. Screen-only UIKit
integrations do not need this wrapper.

```swift
import Skyra
import UIKit

final class FeedbackViewController: UIViewController {
    var skyra: SkyraInstallation!

    @IBAction func giveFeedback(_ sender: UIButton) {
        skyra.presentSurvey(
            slug: "organisation/feedback",
            onOutcome: { result in print("Skyra: \(result)") },
            onError: { error in print("Skyra request failed: \(error)") }
        )
    }
}

window.windowScene = windowScene
let existingRoot = window.rootViewController!
window.rootViewController = SkyraRootViewController(content: existingRoot)
let installation = Skyra.install(
    in: window,
    configuration: .init(organization: "organisation")
)
feedbackViewController.skyra = installation
window.makeKeyAndVisible()
```

Keep `existingRoot` as your navigation/tab root; `window.rootViewController` is now
the Skyra wrapper and should not be cast back to the old controller type. Following
presentation belongs to the installation, not the triggering controller, and
continues across push/pop and tab changes under that stable root. App presentations
may cover it naturally; Skyra does not classify arbitrary covers or add a route
hierarchy API. Display delay continues while covered, pauses while the owning scene is
inactive, and resumes with remaining time when active. Following does not auto-open
after an app restart. Root/window destruction or replacement and scene disconnection
interrupt the request; it does not transfer or reopen elsewhere. Supported saved
progress can be restored by a later explicit trigger; typed text is not natively
restored and may remain live while covered. Custom overlays outside the installed
root and auxiliary windows are not detected or automatically covered/followed.

Ordinary competing requests share one SDK request slot and are not queued.
A screen request may prepare alongside a following survey as described below.
Other competing requests
and report `alreadyPresenting` (through the error callback for following requests,
or by throwing for direct async calls). Availability and hosted-page failures can
still end a request. An omitted slug is resolved through the configured survey
decision; it does not infer a screen or route. An explicit slug bypasses list
selection but still goes through the configured decision and native eligibility.

### Screen priority while following is visible

Following presentation and screen-scoped presentation use distinct ownership rules.
An ordinary app cover does not itself pause, dismiss, or reclassify a following
popup. A screen request can take priority only after its request has resolved to a
survey that is ready to display. If that screen request is loading, delayed,
unavailable, rejected by capture/cooldown, or otherwise does not reach display, the
existing following popup remains visible. This is not a general view-hierarchy or
sheet detector.

When a screen-owned survey is displayed over a following survey, the following
presentation stays hidden for that screen visit after the screen survey completes or
is deliberately closed. Leaving that screen visit resumes the same following survey
and its existing hosted view/session/progress; it does not reload it. If the screen
request resolves to the same survey slug as the existing presentation, the SDK
continues that survey rather than starting it again with a new session. Scene
inactivity pauses following surveys and interrupts a displayed screen-owned survey.

### Unified survey decision

The default decision selects the first response-order `App` candidate when the
request has no explicit slug, then loads delivery policy and applies native
availability, capture, completion/rejection history, and initial-delay rules. If that
candidate is unavailable or ineligible, it does not scan later candidates, queue, or
retry automatically. `SkyraConfiguration.surveyDecision` replaces this
whole business decision, including selection and qualification. Its request-scoped
context exposes `organization`, `requestedSlug`, and `defaultDecision()`. Calling
`defaultDecision()` reuses the SDK's default implementation; repeated or concurrent
calls in the same context share one memoized result. The context does not expose
native history or identity.

For example, keep the SDK's built-in behavior while adopting the unified closure API:

```swift
let configuration = SkyraConfiguration(
    organization: "organisation",
    surveyDecision: { context in
        try await context.defaultDecision()
    }
)
```

Return `.present(slug:initialDelayMilliseconds:)` or `.notShown(reason:)` to supply a
custom complete decision. The SDK still validates the slug and delay and enforces
presentation ownership and host-safety checks, but does not rerun its default
eligibility policy for a custom decision. Explicit requested slugs must be retained;
when the request omitted a slug, a returned slug must belong to the configured
organization. This API does not provide or imply a remote endpoint or transport.

`surveyDecision` is the single decision API for both screen and following requests.
The default survey-list lookup is internal to the SDK.

## UIKit: install at the window and attach to a controller

In your existing scene-based window setup, assign the scene and your root controller
before installing Skyra, then show the window. Use your existing scene and controller:

```swift
import Skyra
import UIKit

window.windowScene = windowScene
window.rootViewController = rootViewController
Skyra.install(in: window, configuration: .init(organization: "organisation"))
// Screen-scoped integration; no wrapper required.
window.makeKeyAndVisible()
```

Install after setting `rootViewController`; a repeated install on the same window
keeps the original installation and configuration. The window retains
the installation. There is no need to pass an SDK through
navigation or tab controllers. In the view controller that should show the survey,
attach it once in `viewDidLoad`:

```swift
import Skyra
import UIKit

final class CheckoutViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        // Keep your existing screen setup here.
        skyraSurvey() // or skyraSurvey("organisation/feedback")
    }
}
```

The attachment requests on appearance and cancels on departure. Cancellation while
waiting for activation, presenter readiness, delivery, or display delay does not
call `onError`. Once presentation has begun, interruption calls `onOutcome` with
`.interrupted`, or `.completed` if acceptance was already confirmed. Re-entering the screen requests
again. Use the optional `onOutcome` and `onError` callbacks for results, as in the
SwiftUI example. The controller retains the attachment; retain
the returned handle only if you need to call `detach()` before the screen leaves.
Detaching interrupts rather than rejecting the survey.

## Custom service addresses and localhost

Normally the SDK uses `https://survey.skyra.no` for hosted pages and
`https://ingest.skyra.no` for delivery. No address configuration is needed.

If Skyra supplied a test environment, create a configuration with those origins:

```swift
let configuration = SkyraConfiguration(
    hostedOrigin: URL(string: "http://localhost:5173")!,
    deliveryOrigin: URL(string: "http://localhost:3212")!
)
```

Pass it to `.skyra(configuration: configuration)` in SwiftUI, or
`Skyra.install(in: window, configuration: configuration)` in UIKit.

Use origins only: do not append `/app.html`, a survey slug, or an API path. HTTP is
accepted only for loopback hosts such as `localhost`; other hosts require HTTPS.

For HTTP localhost testing, open the app target's **Info** tab. Add **App Transport
Security Settings** as a dictionary, then **Allow Local Networking** as Boolean
**YES** inside it. The raw keys are `NSAppTransportSecurity` and
`NSAllowsLocalNetworking`. Add to any existing dictionary rather than replacing
its other entries. **Allow Arbitrary Loads** is not needed.

Use the iOS Simulator for localhost: it reaches services on your Mac. A physical
iPhone's localhost refers to the phone itself. The supplied services must already
be running; the SDK does not start them.

## Screen lifetime and saved progress

| Action | Skyra behavior |
| --- | --- |
| Enter an attached screen | Resolves an explicit slug or selects the configured organization's default, then checks availability, capture, and cooldowns before applying the display delay. |
| Leave during checks or delay | Cancels without recording rejection. |
| Leave an unfinished popup | Removes it, reports `.interrupted`, and preserves supported progress. |
| Return to the screen | Requests again. Valid unfinished progress resumes without the initial delay. |
| Press Close | Records rejection, clears unfinished progress, and reports `.rejected`. |
| Complete the survey | Reports `.completed` after the hosted page confirms final answer acceptance. |

After someone finishes or closes an unfinished survey, that same survey cannot
appear again during its waiting period. In the dashboard, **Retake in** sets the
wait after completion; **Retrigger after** sets it after closing before completion.
For example, with **Retake in** set to one day, a request made earlier will not show
the survey.

When a cooldown blocks a request, it ends immediately. Skyra does not queue the
survey or show it automatically when the cooldown expires. Your app must request it
again later, and that new request is checked against the survey's current settings;
it is not guaranteed to show. This rule applies to screen-scoped and following
requests, whether the request supplies a slug or selects one. It is separate from
**Show after**, the initial delay applied within an eligible request. When default
selection chooses a survey that cannot currently be shown, Skyra does not try a
later survey.

Each participating screen needs an explicit attachment for screen-scoped behavior.
That attachment is intentionally different from explicit following mode above. An
omitted slug in either mode invokes configured selection; an explicit slug bypasses
it. The default decision returns no presentation when there is no App survey.
Screen requests may take priority over following surveys as described above.

With the direct async `presentSurvey` API, cancellation while waiting or preparing
throws `CancellationError`; cancellation of a displayed survey returns `.interrupted`.

If the window is not active when the screen first appears, its request waits for
activation. Once an attempt starts, deactivating the window cancels pending work
or interrupts the popup. Foregrounding alone does not repeat that attempt; leaving
and re-entering the attached screen makes a new request.

By default, native progress persists across app launches. Question position and
supported selections can be restored; typed free-text answers cannot. Saved
records expire after 365 days without an update.

## Design & Preview

Configure theme, fonts, and survey-specific overrides in Skyra's **Design & Preview**.
Review the mobile preview, then check the published survey in your app with its
intended appearance and text-size settings. No Swift styling code is needed for
hosted survey content.

The hosted page owns colors, typography, controls, and internal layout. Swift owns
the floating frame, safe areas, keyboard clearance, drag handle, and outer clipping,
and passes Dynamic Type scale to the page. Larger text may require scrolling.

The popup appears near the bottom trailing corner without dimming the app. While
the keyboard is open, the first tap outside may dismiss it before another tap
activates an app control.

## If the survey does not appear

Add the optional result/error callbacks and read Xcode's console:

| Result or error | Meaning and next step |
| --- | --- |
| `missingRoot` | Add `.skyra()` above the SwiftUI screen, or install in the UIKit window before the attached screen appears. |
| `missingFollowingHost` | Add the SwiftUI `.skyra()` root or wrap the UIKit root in `SkyraRootViewController(content:)` before `Skyra.install(in:)`. |
| `missingOrganization` | Set `organization` in `SkyraConfiguration`, or supply an explicit survey slug. |
| `invalidConfiguration` | Check the supplied origins; use HTTPS except for loopback development hosts. |
| `.notShown(reason: .captureNotSelected)` | Sampling skipped this attempt. Use 100% capture for initial testing. |
| `.notShown(reason: .unavailable)` | Check the slug, publication, iOS type, and questions. |
| `completedCooldown` or `rejectedCooldown` | A prior result is still within its configured waiting period. |
| `presenterUnavailable` | The screen is detached or covered and cannot present. |
| `alreadyPresenting` | Another request or popup is still finishing; requests are not queued. |
| Another error or `.failure(code)` | Check service connectivity; send Skyra the logged error/code if it persists. |

If package resolution fails, confirm repository availability with Skyra. If the
repository is private, also check your GitHub account access in Xcode. If `import Skyra`
fails, check that the package product is linked to the app target.

## Advanced explicit integration

The existing `Skyra`, `SkyraPresenter`, and `presentSurvey(slug:from:)` APIs remain
available for apps that manage presentation directly. Use one integration style
for a screen; do not add a second manual request alongside its survey attachment.
