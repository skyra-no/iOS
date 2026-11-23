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

```swift
let skyra = try Skyra(
    configuration: .init(organization: "acme"),
    storage: SkyraUserDefaultsStorage(defaults: UserDefaults(suiteName: "com.acme.skyra")!)
)
```

`SkyraUserDefaultsStorage` is safe within one process. A suite shared between an app
and an extension isn't: they can overwrite each other's changes. Your own
`SkyraStorage` implements `update(key:_:)`, which must read, transform and write the value
atomically and throw when it can't.
