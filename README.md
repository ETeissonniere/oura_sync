# Oura Sync

A native SwiftUI app for syncing an Oura Horizon Gen 3 directly over Bluetooth. No Oura account is required for pairing or syncing.

![Oura Sync walkthrough](docs/media/oura-sync.gif)

Simulator screenshots and walkthrough use synthetic recordings, not personal health data.

<p>
  <img src="docs/media/heart.png" width="200" alt="Hourly heart-rate chart" />
  <img src="docs/media/sleep.png" width="200" alt="Recorded sleep-stage timeline" />
  <img src="docs/media/nightly-trends.png" width="200" alt="Nightly heart-rate trends" />
  <img src="docs/media/ring.png" width="200" alt="Simulated ring battery and connection states" />
</p>

## What works

- Factory-reset onboarding without existing ring keys.
- Bluetooth history sync, background reconnection, and pull to refresh.
- Apple Health export for supported measurements.
- Heart-rate charts, sleep-stage timelines, nightly trends, and low-battery notifications.

## Current limits

This is an independent implementation, not a replacement for every Oura feature.

- **Steps, calories, and automatic workouts:** not implemented. The research projects omit the proprietary model weights used by their activity pipeline. Activity intensity and movement recordings are available, but are not step counts. Independent estimates are possible; none are presented as measured steps.
- **Advanced scores and predictions:** readiness, stress, resilience, cardiovascular age, fitness, and reproductive predictions are not implemented.
- **Overnight measurements:** HRV, skin temperature, breathing, oxygen, and sleep depend on what the ring records. Their decoders and UI have simulator coverage; validation against this ring’s overnight recordings is pending. Sleep-stage clock times are estimated, so stages are not exported to Apple Health.
- **Background sync:** iOS controls execution. Leave the app in the app switcher; force-quitting can prevent syncing. A short locked-phone sync and Health export test passed, but overnight reliability is still being tested.

## Run

Open `OuraSync.xcodeproj` in Xcode, select your own signing team, and run the `OuraSync` scheme on an iPhone with Developer Mode enabled. The deployment target is iOS 17; Health export of RMSSD requires iOS 27. Development has been tested with Xcode 27.1.

Follow **My ring → Set up my ring** for reset and pairing instructions. Bluetooth is required; Health and notification permissions are optional.

Run protocol tests with `swift test`. App and UI tests run through the Xcode scheme. Simulator media does not demonstrate a live Bluetooth connection.

## Research

Built from [open_oura](https://github.com/Th0rgal/open_oura) and [open_health](https://github.com/Th0rgal/open_health). Upstream attribution is preserved in [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES). Not affiliated with Oura.
