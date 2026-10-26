import Charts
import SwiftUI

struct TrendsView: View {
  @Environment(RingCoordinator.self) private var ring
  let preview: Bool
  @State private var days = 7
  var body: some View {
    PageHeading(title: "The bigger picture.", subtitle: "Your patterns, one day at a time.")
    if preview {
      Picker("Time range", selection: $days) {
        Text("7 days").tag(7)
        Text("30 days").tag(30)
      }
      .pickerStyle(.segmented)
      Surface(prominent: true) {
        Text("RESTING HEART RATE").font(.caption2.weight(.semibold)).tracking(1.3)
        Text(days == 7 ? "53 bpm" : "55 bpm").font(.largeTitle)
        Text("\(days)-day average").font(.caption).foregroundStyle(Color.secondaryInk)
        Chart(Array(values.enumerated()), id: \.offset) { point in
          LineMark(
            x: .value("Day", point.offset + 1), y: .value("Resting heart rate", point.element)
          )
          .foregroundStyle(Color.forest)
        }
        .chartYScale(domain: 45...65)
        .chartXAxisLabel("Day in selected period")
        .chartYAxisLabel("bpm")
        .frame(height: 170)
      }
      Text("Your averages").font(.headline)
      VStack(spacing: 0) {
        DetailRow(title: "Time asleep", value: days == 7 ? "7h 04m" : "7h 12m")
        Divider()
        DetailRow(title: "HRV · RMSSD", value: days == 7 ? "46 ms" : "43 ms")
        Divider()
        DetailRow(title: "Daily steps", value: days == 7 ? "6,840" : "7,120")
      }
      Text("Averages use available recordings. Missing days are never treated as zero.")
        .font(.caption).foregroundStyle(Color.secondaryInk)
    } else if !ring.measurements.isEmpty {
      Picker("Time range", selection: $days) {
        Text("7 days").tag(7)
        Text("30 days").tag(30)
      }.pickerStyle(.segmented)
      if ring.nightlyVitals.isEmpty {
        RecordedVitalsView(measurements: ring.measurements, days: days)
      } else {
        NightlyTrendsView(nights: ring.nightlyVitals, days: days)
        DisclosureGroup("All recordings") {
          RecordedVitalsView(measurements: ring.measurements, days: days)
            .padding(.top, 16)
        }
        .font(.subheadline)
      }
    } else {
      EmptyMeasurements(
        title: "Patterns take time.",
        message:
          "Sync your ring to start building a picture of your sleep, heart rate, and activity. Missing days won’t count as zero."
      )
    }
  }

  private var values: [Double] {
    days == 7
      ? [56, 53, 55, 51, 53, 50, 52]
      : [
        58, 57, 55, 56, 54, 56, 55, 57, 58, 56, 55, 54, 52, 55, 56, 54, 53, 55, 56, 54, 55, 53, 54,
        52, 53, 51, 53, 50, 52, 53,
      ]
  }
}
