# Reference: state and sync

Details behind the [guide](Installation.md). You don't need them to integrate the SDK.

## Merge rules

`sync` is the only call that writes state.

- The visitor ID that was created first is kept. Visitor IDs are ULIDs, which include
  their creation time; one dated in the future throws `SkyraError.invalidState`.
- For each survey, the entry with the later `lastSync` (Unix milliseconds) wins. On
  equal times the state further along wins: `Selected`, `Capture`, `Rejected`,
  `Completed`.
- Entries for other organisations, entries more than 400 days old, entries dated more
  than five minutes ahead and malformed entries are ignored.
- Progress is kept only while a survey is `Capture`: at most 64 KB per survey and
  1 MB in total.
- At most 200 surveys are kept. Over a limit, the oldest goes first.

Syncing the same state twice changes nothing.

## JSON shape

`SkyraState(json:)`, `SkyraState(jsonObject:)` and `json()` use this shape. A survey
in progress also carries a `progress` object.

```json
{
  "visitorId": "01JD8ZQ6K3Y7M2N4P5R6S7T8V9",
  "surveys": {
    "acme/feedback": { "state": "Completed", "lastSync": 1794832273590, "sessionId": "01JD8ZR1M4XQ2B7C9D0E1F2G3H" }
  }
}
```

## Custom storage

Most apps don't need this. By default the SDK keeps its state in the app's standard
UserDefaults. Use your own storage if you want Skyra's data apart from the app's
settings, for example to clear it on logout without touching anything else, or to
keep it encrypted or in a file.

```swift
let skyra = try Skyra(
    configuration: .init(organization: "acme"),
    storage: SkyraUserDefaultsStorage(defaults: UserDefaults(suiteName: "com.acme.skyra")!)
)
```

Don't use a UserDefaults suite shared by the app and an extension, such as a widget:
if both write at the same time, one can overwrite the other's changes.

Your own `SkyraStorage` implements `update(key:_:)`. It must read, change and write
the value in one go, so nothing else writes in between, and throw if it fails.
