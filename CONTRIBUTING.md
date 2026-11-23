# Contributing

## Scope

The SDK stores the visitor's survey state, asks the decision service which surveys to
show, and merges in what the widget reports. It decides nothing itself and has no UI.
Requests and responses follow Skyra's survey decision contract. Keep the docs in step
with the public API in `Sources/Skyra`, and keep demo apps out of the package.

## Checks

The minimum is Xcode 16.0 with Swift 5 language mode. Run from the repository root:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
bash Scripts/format-swift.sh          # formats; add --lint to only check
bash Scripts/check-package.sh         # needs jq
swift test
xcodebuild -scheme Skyra -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath DerivedData test
```

The format script downloads a pinned, checksum-verified SwiftFormat into `.build/` on
first use.

CI runs on every pull request and on `main`: formatting and the package check on
Linux, and `swift test` on Xcode 16.0. Simulator tests on newer Xcode versions run
only when started by hand under **Actions → Swift Package → Run workflow**, so run
them locally for changes that touch iOS behaviour.

## Pull requests

Open one against `main` with the problem, the change and how you tested it. Add tests
for behaviour changes and update the guide. Source files: `Storage.swift`,
`SkyraState.swift`, `DecisionService.swift` and `BoundedTransport.swift` cover what is
stored and sent, so check `Documentation/Privacy.md` when you change them.

Report bugs in [GitHub Issues](https://github.com/skyra-no/iOS/issues). Leave out
credentials, survey answers and customer data.
