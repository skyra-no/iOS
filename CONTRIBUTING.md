# Contributing

Skyra is an iOS beta, licensed under [MIT](LICENSE).

## Scope

This package is a headless Swift toolkit: it stores the visitor's survey state, calls
the decision service, and merges state from the app and the web widget. It shows no UI. Showing surveys is the
integrating app's job, usually with the Skyra widget in a web view. Keep demo applications, local automation configuration, and
runtime evidence out of the package.

Request and response shapes follow Skyra's survey decision contract. Keep the
documentation aligned with the public API in `Sources/Skyra`.

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
Automatic PR and main-branch CI checks formatting and the package contract, and builds
and tests the package on macOS with the declared minimum Xcode 15.0.1 / Swift 5.9
toolchain. Newer Xcode builds and simulator tests are manual-only through **Actions →
Swift Package → Run workflow**. The manual matrix uses macOS 15 with Xcode 16.4 and
26.3; it does not establish iOS 15 runtime coverage. Public requirements remain unchanged. Do not imply readiness or
validation counts without results from the validation owner for the relevant revision.

## Review

Open a pull request against `main` with the problem, change, and checks performed.
Keep changes focused and preserve historical test evidence. Test-result summaries
should identify the revision, toolchain, runtime, and limits of the test.

Use [GitHub Issues](https://github.com/skyra-no/iOS/issues) for reproducible
bugs and integration questions. Do not include credentials, personal survey
answers, or private customer data in reports or screenshots.
