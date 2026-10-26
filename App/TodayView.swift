import SwiftUI

struct TodayView: View {
  @Environment(RingCoordinator.self) private var ring
  let preview: Bool
  let showSleep: () -> Void
  let showRing: () -> Void
  @State private var showLiveHeartRate = false

  var body: some View {
    PageHeading(
      title: "Your day, in rhythm.",
      subtitle: Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()))
    Button(action: showRing) {
      HStack(spacing: 8) {
        Image(systemName: preview ? "checkmark.circle.fill" : "circle.dotted")
        Text(
          preview
            ? "Preview · Ring 82%"
            : ring.pairing?.confirmed == true ? ring.message : "Connect your ring")
        Image(systemName: "chevron.right").font(.caption2)
      }
      .font(.caption)
      .padding(.horizontal, 14).padding(.vertical, 12)
      .background(Color.softGreen, in: .capsule)
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)

    if preview {
      HStack {
        Text("Last night").font(.title2)
        Spacer()
        Text("Sample night").font(.caption).foregroundStyle(Color.secondaryInk)
      }
      Surface(prominent: true) {
        SleepTotal()
        SleepTimeline()
        Button(action: showSleep) {
          HStack {
            Text("Explore your sleep")
            Spacer()
            Image(systemName: "arrow.right")
          }
          .font(.subheadline).frame(minHeight: 44).padding(.top, 8)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .top, spacing: 12) { metrics }
        VStack(spacing: 12) { metrics }
      }
      DetailRow(title: "Movement so far", value: "3,842 steps")
    } else if !ring.measurements.isEmpty || !ring.sleepPeriods.isEmpty {
      if let period = ring.sleepPeriods.last {
        RecordedSleepSummary(period: period, showSleep: showSleep)
      }
      RecordedVitalsView(measurements: ring.measurements)
    } else if ring.pairing?.confirmed == true {
      EmptyMeasurements(
        title: "Your ring is collecting.",
        message:
          "Wear your ring to start recording. Heart-rate readings and your first night’s sleep will appear after they sync."
      )
      if let date = ring.lastSync {
        DetailRow(
          title: "Last complete sync", value: date.formatted(date: .abbreviated, time: .shortened))
      }
      Button(ring.busy ? "Syncing…" : "Sync now") { Task { await ring.sync() } }
        .buttonStyle(PrimaryButtonStyle()).disabled(ring.busy)
    } else {
      EmptyMeasurements(
        title: "Your story starts here.",
        message:
          "Connect your Horizon ring to see sleep, heart rate, and movement collected on your terms."
      )
      Button("Set up my ring", action: showRing).buttonStyle(PrimaryButtonStyle())
      Text(
        "No account. No cloud. Your measurements stay on your iPhone unless you choose to share them with Apple Health."
      )
      .font(.subheadline).foregroundStyle(Color.secondaryInk)
    }
    if !preview, ring.pairing?.confirmed == true {
      Button {
        showLiveHeartRate = true
      } label: {
        Label("Measure live heart rate", systemImage: "waveform.path.ecg")
          .font(.subheadline.weight(.medium)).frame(minHeight: 44)
      }
      .buttonStyle(.plain)
      .sheet(isPresented: $showLiveHeartRate) {
        LiveHeartRateView(
          session: ring.liveHeartRate, syncing: ring.busy,
          start: { ring.startLiveHeartRate() }, stop: { ring.stopLiveHeartRate() })
      }
    }
  }

  @ViewBuilder private var metrics: some View {
    metric("Resting heart rate", value: "52", unit: "bpm", detail: "Overnight")
    metric("Heart rate variability", value: "48", unit: "ms", detail: "RMSSD · Overnight")
  }

  private func metric(_ title: String, value: String, unit: String, detail: String) -> some View {
    Surface {
      Text(title).font(.caption).foregroundStyle(Color.secondaryInk)
      HStack(alignment: .firstTextBaseline, spacing: 4) {
        Text(value).font(.largeTitle).tracking(-1)
        Text(unit).font(.caption).foregroundStyle(Color.secondaryInk)
      }
      Text(detail).font(.caption).foregroundStyle(Color.secondaryInk)
    }
    .accessibilityElement(children: .combine)
  }
}
