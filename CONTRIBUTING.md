# Contributing

Skyra is an unreleased iOS beta, licensed under [MIT](LICENSE).

## Scope

This package contains the native Swift SDK and tests. Hosted survey rendering is
provided by Skyra's service. Keep hosted implementation source, demo applications,
local automation configuration, and runtime evidence out of the package.

The customer API supports screen-scoped attachments and explicitly triggered,
installation-owned following presentation. Either accepts an exact slug or, when
omitted, selects through `SkyraConfiguration.surveyDecision`. The default decision
selects the first response-order App survey from delivery and applies native
eligibility. A custom decision replaces both selection and eligibility. Keep documentation
aligned with these public behaviors rather than describing internal prototypes.

## Checks

The declared minimums are Swift 5.9, Swift 5 language mode, and Xcode 15.0.1 for iOS
development. These requirements are not a claim that every change has been tested
on every minimum version. Run from the repository root:

```sh
bash Scripts/format-swift.sh
bash Scripts/format-swift.sh --lint
bash Scripts/check-package.sh
```

Package-contract validation requires `jq`. The formatter script downloads a pinned,
checksum-verified SwiftFormat binary into `.build/` on first use.

For native changes, run the relevant package and simulator tests with the selected
Xcode developer directory; commands are in the [README](README.md#development-checks).
Add meaningful tests and update customer documentation for behavior changes.
Automatic PR and main-branch CI checks formatting and the package contract. Expensive
Xcode builds and simulator tests are manual-only through **Actions → Swift Package →
Run workflow**. The manual matrix uses macOS 15 with Xcode 16.4 and 26.3, not the
declared minimum Xcode 15.0.1 / Swift 5.9 toolchain; it does not establish iOS 15
runtime coverage. Public requirements remain unchanged. Do not imply readiness or
validation counts without results from the validation owner for the relevant revision.

## Review

Open a pull request against `main` with the problem, change, and checks performed.
Keep changes focused and preserve historical test evidence. Test-result summaries
should identify the revision, toolchain, runtime, and limits of the test.

Use [GitHub Issues](https://github.com/skyra-no/iOS/issues) for reproducible
bugs and integration questions. Do not include credentials, personal survey
answers, or private customer data in reports or screenshots.
