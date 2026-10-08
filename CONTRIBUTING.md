# Contributing to Tracker

Thanks for your interest in improving Tracker! Bug reports, receiver compatibility notes and pull requests are all welcome.

## Before you start

- For larger changes (new settings, payload fields, protocol changes), please open an issue first so we can agree on the design.
- Tracker's focus is **configurability and reliable delivery**, not visualizing data in the app. Features that show maps or history are out of scope.

## Setting up

1. Install Xcode 26 or later.
2. Copy `Config/Signing.local.xcconfig.example` to `Config/Signing.local.xcconfig` if you want to run on a device.
3. Open `Tracker.xcodeproj`.

## Guidelines

- **Logic belongs in TrackerKit.** Anything that doesn't need UIKit or Core Location at runtime (payloads, configuration, queueing, uploading) goes in `Packages/TrackerKit` and comes with tests.
- **Run the tests:** `swift test --package-path Packages/TrackerKit`.
- **Keep the wire format compatible.** GeoJSON output must stay compatible with existing receivers. New properties must be opt-in through `PayloadFields`.
- **Keep the configuration format compatible.** Add new configuration keys with defaults in the custom `init(from:)` so older exports still import.
- **Match the existing style:** Swift 6 strict concurrency, `@Observable`, native SwiftUI controls, and Liquid Glass only for interactive controls.
- **Don't add dependencies** unless there's no reasonable alternative.

## Testing against a receiver

`scripts/dev-receiver.py` prints everything it receives and can simulate failures (`--fail`), require a token (`--token`) or push remote configuration (`--set`).
