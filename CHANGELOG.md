# Changelog

Until 1.0, a new minor version can change the API. A patch version does not.

## 0.1.0

First version.

- `Skyra.getSurveys(traits:)` asks the decision service which surveys to show.
- `Skyra.widgetConfig()` gives a web view the configuration and saved state for the Skyra widget.
- `Skyra.sync(_:)` merges the widget's state into the state stored on the device.
- `Skyra.state()` returns the stored state.
