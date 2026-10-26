import OuraProtocol
import SwiftUI

struct NightlyVitalsView: View {
  let summary: NightlyVitals

  var body: some View {
    Surface {
      Label("During detected bedtime", systemImage: "moon.stars").font(.headline)
      Text(
        "\(summary.start.formatted(date: .abbreviated, time: .shortened)) – \(summary.end.formatted(date: .abbreviated, time: .shortened))"
      )
      .font(.caption).foregroundStyle(Color.secondaryInk)
      VStack(alignment: .leading, spacing: 8) {
        vital("Average heart rate", summary.heartRate, unit: "bpm")
        if let heart = summary.heartRate {
          Text("Lowest recorded average: \(formatted(heart.minimum)) bpm")
            .font(.caption).foregroundStyle(Color.secondaryInk)
        }
        Divider()
        vital("Average HRV", summary.hrv, unit: "ms")
        Divider()
        vital("Average breathing rate", summary.respiratoryRate, unit: "breaths/min", precision: 1)
        Divider()
        vital("Average blood oxygen", summary.oxygenSaturation, unit: "%", precision: 1)
        Divider()
        DetailRow(
          title: "Sleeping skin temperature",
          value: summary.skinTemperature.map { "\(formatted($0, precision: 2)) °C" }
            ?? "Awaiting consistent readings")
      }
      Text(
        "Based on available recordings within the ring’s detected bedtime, which can include time awake. Coverage may be partial. Heart rate and HRV use five-minute recordings; short daytime readings are excluded. HRV is measured as RMSSD; skin temperature is measured at your finger."
      )
      .font(.caption).foregroundStyle(Color.secondaryInk)
    }
  }

  private func vital(_ title: String, _ reading: NightlyVital?, unit: String, precision: Int = 0)
    -> some View
  {
    VStack(alignment: .leading, spacing: 0) {
      DetailRow(
        title: title,
        value: reading.map { "\(formatted($0.average, precision: precision)) \(unit)" }
          ?? "Awaiting readings")
      if let reading {
        Text("\(reading.count.formatted()) recordings")
          .font(.caption2).foregroundStyle(Color.secondaryInk)
      }
    }
  }

  private func formatted(_ value: Double, precision: Int = 0) -> String {
    value.formatted(.number.precision(.fractionLength(precision)))
  }
}
