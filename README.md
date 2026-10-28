# Oura Sync

> [!WARNING]
> This project is almost entirely vibecoded as an experiment to see if I could replace the unnecessary and frustrating Oura membership with a proper offline iOS app. Use at your own risks.

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

- **Steps, calories, and automatic workouts:** not implemented. Activity intensity and movement recordings are available, but are not step counts. `open_health` estimates displayed steps from fixed cadences at MET thresholds; we do not use that heuristic. Its model-based workout pipeline is separate and requires proprietary weights omitted from the repository.
- **Advanced scores and predictions:** readiness, stress, resilience, cardiovascular age, fitness, and reproductive predictions are not implemented.
- **Oxygen calibration:** raw recordings are retained, including values above 100. In-app charts now use minute estimates from reconstructed Gen 3 signal-quality processing and carry an unvalidated-calibration warning. Filtering does not establish accuracy. Apple Health exports are disabled, including when permission was previously granted. We do not apply guessed offsets, clamps, or calibration formulas for other hardware. A personal baseline will not resolve an unknown sensor conversion. Re-enabling export requires a supported Gen 3 processing method and matching overnight reference recordings. Previously exported samples are not automatically deleted or corrected.
- **Overnight measurements:** HRV, skin temperature, breathing, oxygen, and sleep records have been received from a Horizon Gen 3 after a night of wear. This confirms data availability, not sensor accuracy. Complete, finalized sleep-stage recordings use the ring summary's start and duration; unused final-page slots are excluded. This rule was recovered from the Android app's native Gen 3 consumer. Incomplete or ambiguous recordings remain estimated and are withheld from Health. These are firmware stages, not Oura's newer phone-model results. Charts preserve short stage changes rather than smoothing them away.
- **Background sync:** iOS controls execution. Leave the app in the app switcher; force-quitting can prevent syncing. Controlled background transfers and a short locked-phone sync with Health export have passed; autonomous overnight reliability remains unverified. **My ring → Sync details** shows the latest actual foreground and background transfers. Foreground downloads continue until caught up; background downloads save progress within a limited execution window.

Apple Health receives permitted heart-rate, respiratory-rate, RMSSD HRV (iOS 27+), **in-bed**, and complete firmware sleep-stage records. In-bed time is not time asleep. Updated sleep recordings replace only Oura Sync's stages for that night; interrupted exports remain pending for retry. Finger skin temperature is not exported as body or Apple Watch wrist temperature. We do not export derived resting heart rate, steps, calories, or workouts. Raw history stays on the phone so decoding can improve without losing the original recordings.

### Oxygen processing research

The Gen 3 consumer in Oura Android **7.15.0** does more than read the ring's oxygen bytes: it aligns timestamps, combines motion and optical recordings, rejects poor signals, classifies dips, and produces minute averages. Our Swift implementation now applies that pipeline to recorded events for in-app charts. The port matches all 475 dip-classification probabilities and 807 minute outputs in the captured comparison; raw recordings remain untouched.

A local replay connected the original ARM64 dispatcher, packet processing, embedded configuration, dip detector, classifier, and output routines. Across all 42 batches from 51,904 recorded events, the reconstruction matched 64,357 quality evaluations and final sample decisions, plus 807 minute outputs. This includes a batch with a backward timestamp step, preserved without sorting or smoothing. A separate run of the native clock resolver matched the app’s UTC mapping for all research events. Stored event ordering may differ from original wire order, and host implementations replace supporting library calls. This is not a complete app-level replay or an accuracy comparison against a reference device.

The Android app also has an optional, remotely configured correction to the **daily average**. That is not evidence for adding an offset to every reading, nor a recovered personal-calibration procedure. Native minute-quality flags describe the fraction of accepted samples, not continuous recording coverage. Runtime configuration differences and accuracy against overnight reference recordings remain unresolved, so Health export stays disabled.

### Sleep-stage timing

Static inspection of Oura Android **7.15.0** (`libappecore.so`, `sleepinfo_process_event`) resolved the Gen 3 alignment and padding rule:

- `0x49` supplies the start and end as minute offsets from its event time. The first stage starts at that summary start.
- Each `0x5a` page contains 52 thirty-second stages, or 26 minutes. The summary duration determines how many stages are valid; remaining slots in the last page are ignored regardless of their value.
- `0x4c` finalizes the recording. Export requires complete sequential pages, an unambiguous summary/finalization pair, supported summary fields, and agreement with the independent bedtime record.

For example, a 582-minute night needs 23 pages with 598 minutes of capacity. The extra 16 minutes are unused slots, not additional awake time. Trimming every trailing awake code would also remove real wakefulness; stretching the stages would shift their timestamps. [The decoder](Sources/OuraProtocol/SleepStages.swift) records the native binary fingerprint and instruction addresses behind this rule.

Deep, light, REM, and awake map to Health's Deep, Core, REM, and Awake categories. A persistent journal makes exports retryable and replaces shortened or corrected nights without leaving stale stages. Missing or partial snapshots do not retract a previously completed night. This recovers the firmware's timing contract; it does not validate its clinical accuracy or reproduce Oura's newer phone-based sleep model.

## Run

Open `OuraSync.xcodeproj` in Xcode, select your own signing team, and run the `OuraSync` scheme on an iPhone with Developer Mode enabled. The deployment target is iOS 17; Health export of RMSSD requires iOS 27. Development has been tested with Xcode 27.1.

Follow **My ring → Set up my ring** for reset and pairing instructions. Bluetooth is required; Health and notification permissions are optional.

Run protocol tests with `swift test`. App and UI tests run through the Xcode scheme. Simulator media does not demonstrate a live Bluetooth connection.

## Research

Built from [open_oura](https://github.com/Th0rgal/open_oura) and [open_health](https://github.com/Th0rgal/open_health). Upstream attribution is preserved in [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES). Not affiliated with Oura.
