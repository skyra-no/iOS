# Development

For Skyra's developers working on the SDK.

## Checks

```sh
bash Scripts/format-swift.sh          # formats; add --lint to only check
bash Scripts/check-package.sh         # needs jq
swift test
# Simulator tests; pick any simulator your Xcode has:
xcodebuild -scheme Skyra -destination 'platform=iOS Simulator,name=iPhone 16' test
```

With several Xcode versions installed, set `DEVELOPER_DIR` to the one you want.

## CI

Every pull request and push to `main` runs the format and package checks, and
`swift test` on Xcode 16.0, the declared minimum. Simulator tests on newer Xcode
versions run only when started under **Actions → Swift Package → Run workflow**.

## Pull requests

- Add tests for behaviour changes and update `Documentation/Installation.md`.
- `Storage.swift`, `SkyraState.swift`, `DecisionService.swift` and
  `BoundedTransport.swift` define what is stored and sent. Update
  `Documentation/Privacy.md` when you change them.
- Keep demo apps out of the package.
