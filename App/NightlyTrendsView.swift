import Charts
import OuraProtocol
import SwiftUI

struct NightlyTrendsView: View {
  let nights: [NightlyVitals]
  let days: Int
  @State private var metric = NightMetric.heartRate
  @State private var selectedDate: Date?
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  private var valueLayout: AnyLayout {
    dynamicTypeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
      : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 6))
  }

  private var range: ClosedRange<Date> {
    let now = Date.now
    let start = Calendar.current.date(byAdding: .day, value: -max(1, days), to: now) ?? now
    return start...now
  }

  private var recordings: [NightlyVitals] {
    let window = range
    return nights.filter {
      window.contains($0.end) && metric.value($0) != nil
    }.sorted { $0.end == $1.end ? $0.id < $1.id : $0.end < $1.end }
  }

  private var displayedNight: NightlyVitals? {
    guard let selectedDate else { return recordings.last }
    return recordings.min {
      abs($0.end.timeIntervalSince(selectedDate)) < abs($1.end.timeIntervalSince(selectedDate))
    }
  }

  var body: some View {
    Surface {
      Text("Nightly trends").font(.headline)
      Picker("Nightly metric", selection: $metric) {
        ForEach(NightMetric.allCases) { metric in
          Text(metric.title).tag(metric)
        }
      }
      .pickerStyle(.menu).tint(Color.forest)
      .accessibilityIdentifier("nightlyMetricPicker")
      if let night = displayedNight, let value = metric.value(night) {
        VStack(alignment: .leading, spacing: 6) {
          valueLayout {
            Text(metric.formatted(value)).font(.system(.largeTitle, design: .rounded))
            Text(metric.unit).font(.subheadline).foregroundStyle(Color.secondaryInk)
          }
          .accessibilityElement(children: .combine)
          Text(
            "\(selectedDate == nil ? "Latest" : "Selected") · \(night.end.formatted(date: .abbreviated, time: .shortened))"
          )
          .font(.caption).foregroundStyle(Color.secondaryInk)
          Text("During detected bedtime")
            .font(.caption).foregroundStyle(Color.secondaryInk)
        }
        chart
        if metric == .oxygen {
          Text("Oxygen calibration is unverified. Not exported to Apple Health.")
            .font(.caption).foregroundStyle(Color.secondaryInk)
        }
        Text(
          metric == .temperature
            ? "Each point is one nightly skin-temperature estimate."
            : "Points show recorded averages. Faint bars show the lowest and highest readings."
        )
        .font(.caption).foregroundStyle(Color.secondaryInk)
        Text(coverage)
          .font(.caption).foregroundStyle(Color.secondaryInk)
        Text("Touch and drag to inspect a night. Missing nights stay empty.")
          .font(.caption).foregroundStyle(Color.secondaryInk)
      } else {
        Text("Awaiting \(metric.title.lowercased()) recordings")
          .font(.subheadline.weight(.medium))
        Text(
          "No valid readings during detected bedtimes in the last \(days) days. Sync after wearing your ring overnight."
        )
        .font(.subheadline).foregroundStyle(Color.secondaryInk)
      }
    }
    .onChange(of: metric) { _, _ in selectedDate = nil }
    .onChange(of: days) { _, _ in selectedDate = nil }
  }

  private var coverage: String {
    let count = recordings.count
    let nightsLabel = count == 1 ? "1 detected bedtime" : "\(count) detected bedtimes"
    guard metric != .temperature else { return "\(nightsLabel) · Last \(days) days" }
    let samples = recordings.reduce(0) { $0 + (metric.summary($1)?.count ?? 0) }
    return "\(nightsLabel) · \(samples) recordings · Last \(days) days"
  }

  private var chart: some View {
    Chart(recordings) { night in
      if let value = metric.value(night) {
        if let summary = metric.summary(night) {
          RuleMark(
            x: .value("Bedtime end", night.end),
            yStart: .value("Lowest", summary.minimum),
            yEnd: .value("Highest", summary.maximum)
          )
          .foregroundStyle(Color.forest.opacity(0.2)).lineStyle(StrokeStyle(lineWidth: 2))
          .accessibilityHidden(true)
        }
        PointMark(x: .value("Bedtime end", night.end), y: .value(metric.title, value))
          .foregroundStyle(Color.forest)
          .symbolSize(displayedNight?.id == night.id && selectedDate != nil ? 65 : 30)
          .accessibilityLabel(
            "\(metric.title), bedtime ending \(night.end.formatted(date: .abbreviated, time: .shortened))"
          )
          .accessibilityValue("\(metric.formatted(value)) \(metric.unit)")
      }
    }
    .chartXScale(domain: range)
    .chartYScale(domain: .automatic(includesZero: false))
    .chartXAxis {
      AxisMarks(values: .automatic(desiredCount: days > 7 ? 4 : 3)) { _ in
        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
      }
    }
    .chartYAxis {
      AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
        AxisGridLine().foregroundStyle(Color.secondaryInk.opacity(0.12))
        AxisValueLabel()
      }
    }
    .chartXSelection(
      value: Binding(
        get: { selectedDate }, set: { if let date = $0 { selectedDate = date } })
    )
    .frame(height: 155)
    .accessibilityLabel("Nightly \(metric.title.lowercased()) chart")
    .accessibilityHint("Select a date to inspect the nearest recorded bedtime.")
  }
}

private enum NightMetric: String, CaseIterable, Identifiable {
  case heartRate, hrv, breathing, oxygen, temperature
  var id: Self { self }

  var title: String {
    switch self {
    case .heartRate: "Heart rate"
    case .hrv: "Heart rate variability"
    case .breathing: "Breathing rate"
    case .oxygen: "Blood oxygen"
    case .temperature: "Skin temperature"
    }
  }

  var unit: String {
    switch self {
    case .heartRate: "bpm"
    case .hrv: "ms RMSSD"
    case .breathing: "breaths/min"
    case .oxygen: "%"
    case .temperature: "°C"
    }
  }

  func summary(_ night: NightlyVitals) -> NightlyVital? {
    let result: NightlyVital?
    switch self {
    case .heartRate: result = night.heartRate
    case .hrv: result = night.hrv
    case .breathing: result = night.respiratoryRate
    case .oxygen: result = night.oxygenSaturation
    case .temperature: result = nil
    }
    guard let result, result.count > 0,
      [result.average, result.minimum, result.maximum].allSatisfy({ $0.isFinite && $0 > 0 }),
      result.minimum <= result.maximum
    else { return nil }
    return result
  }

  func value(_ night: NightlyVitals) -> Double? {
    if self == .temperature {
      guard let value = night.skinTemperature, value.isFinite, value > 0 else { return nil }
      return value
    }
    return summary(night)?.average
  }

  func formatted(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(self == .temperature ? 2 : 1)))
  }
}
