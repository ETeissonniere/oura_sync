import Charts
import OuraProtocol
import SwiftUI

struct MetricPresentation: Identifiable {
  let kind: MeasurementKind
  let title: String
  let unit: String
  let explanation: String
  let precision: Int
  var id: MeasurementKind { kind }

  static let all: [Self] = [
    .init(
      kind: .heartRate, title: "Heart rate", unit: "bpm",
      explanation:
        "Heartbeats per minute. Includes ring-recorded five-minute averages and packet averages estimated from quality-filtered daytime beats. These readings have different recording intervals.",
      precision: 0),
    .init(
      kind: .hrvRMSSD, title: "Heart rate variability", unit: "ms",
      explanation:
        "Beat-to-beat variation, measured as RMSSD in milliseconds. The chart shows how your own recordings change over time.",
      precision: 0),
    .init(
      kind: .skinTemperature, title: "Sleeping skin temperature", unit: "°C",
      explanation:
        "Temperature at your finger during sleep. Skin temperature differs from the core body temperature measured by a thermometer.",
      precision: 2),
    .init(
      kind: .respiratoryRate, title: "Breathing rate", unit: "breaths/min",
      explanation: "Breaths per minute recorded while you sleep.", precision: 1),
    .init(
      kind: .oxygenSaturation, title: "Blood oxygen", unit: "%",
      explanation: "Your ring’s estimate of blood oxygen saturation during recorded periods.",
      precision: 0),
    .init(
      kind: .activityMET, title: "Activity intensity", unit: "MET",
      explanation:
        "Energy use relative to rest: 1 MET represents resting energy use. Values summarize batches of activity readings.",
      precision: 1),
    .init(
      kind: .motionSeconds, title: "Movement", unit: "s/record",
      explanation:
        "Seconds of movement reported in each ring recording. The chart summarizes individual recording windows, not your total active time or step count.",
      precision: 1),
  ]
}

struct MetricChartCard: View {
  let metric: MetricPresentation
  let samples: [OuraProtocol.Measurement]
  let days: Int
  let range: ClosedRange<Date>
  private let buckets: [MeasurementBucket]
  private let lineSeries: [Date: Int]
  private let timeSlots: [DateInterval]
  @State private var selectedDate: Date?
  @Environment(\.colorScheme) private var colorScheme

  init(
    metric: MetricPresentation, samples: [OuraProtocol.Measurement], days: Int,
    range: ClosedRange<Date>
  ) {
    self.metric = metric
    self.samples = samples.sorted { $0.end < $1.end }
    self.days = days
    self.range = range
    let interval: Calendar.Component = days == 1 ? .hour : .day
    let buckets = MeasurementBuckets(samples: samples, interval: interval).values
    self.buckets = buckets
    var series: [Date: Int] = [:]
    var run = 0
    var previousEnd: Date?
    for bucket in buckets {
      // A new series prevents Charts from drawing across an unrecorded interval.
      if bucket.start != previousEnd { run += 1 }
      series[bucket.id] = run
      previousEnd = bucket.end
    }
    lineSeries = series
    var slots: [DateInterval] = []
    var next = range.lowerBound
    while next < range.upperBound,
      let slot = Calendar.current.dateInterval(of: interval, for: next), slot.end > next
    {
      slots.append(slot)
      next = slot.end
    }
    timeSlots = slots
  }

  private var selected: MeasurementBucket? {
    guard let selectedDate else { return nil }
    return buckets.first { $0.start <= selectedDate && selectedDate < $0.end }
  }

  private var displayedValue: Double {
    if let selected { return selected.average }
    if days == 1 { return samples.last?.value ?? 0 }
    return samples.reduce(0) { $0 + $1.value } / Double(samples.count)
  }

  private var valueLabel: String {
    if selectedDate != nil && selected == nil {
      return days == 1 ? "No recording in this hour" : "No recording on this day"
    }
    if selected != nil {
      let period = days == 1 ? "Selected hour" : "Selected day"
      return metric.kind == .activityMET
        ? "\(period) · average of batch means" : "\(period) · average"
    }
    if days == 1 { return "Latest recorded reading" }
    return metric.kind == .activityMET
      ? "Average of recorded batch means" : "Average of recorded readings"
  }

  private var readingLabel: String { metric.kind == .activityMET ? "batch means" : "readings" }

  private var usesTrace: Bool { metric.kind == .heartRate || metric.kind == .respiratoryRate }
  private var intensityMaximum: Double { max(1, buckets.map(\.average).max() ?? 1) }

  private var verticalRange: ClosedRange<Double> {
    let low = buckets.map(\.minimum).min() ?? 0
    let high = buckets.map(\.maximum).max() ?? 1
    let padding = max((high - low) * 0.15, metric.kind == .skinTemperature ? 0.1 : 1)
    return max(0, low - padding)...(high + padding)
  }

  var body: some View {
    Surface(prominent: metric.kind == .heartRate) {
      Text(metric.title).font(.headline)
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .firstTextBaseline, spacing: 6) { valueAndUnit }
        VStack(alignment: .leading, spacing: 2) { valueAndUnit }
      }
      .accessibilityElement(children: .combine)
      VStack(alignment: .leading, spacing: 4) {
        Text(valueLabel).font(.caption.weight(.medium))
        Text(detail).font(.caption)
      }
      .foregroundStyle(Color.secondaryInk)
      chart
      legend
      if selectedDate != nil {
        Button("Show summary") { selectedDate = nil }.font(.caption)
      } else {
        Text("Touch and drag to explore").font(.caption).foregroundStyle(Color.secondaryInk)
      }
      DisclosureGroup("About this metric") {
        Text(metric.explanation).font(.subheadline).foregroundStyle(Color.secondaryInk)
          .padding(.top, 6)
      }
      .font(.subheadline)
    }
  }

  @ViewBuilder private var legend: some View {
    if metric.kind == .activityMET {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 10) {
          Text("0 MET")
          RoundedRectangle(cornerRadius: 3)
            .fill(
              LinearGradient(
                colors: [.forest.opacity(0.18), .forest], startPoint: .leading, endPoint: .trailing)
            )
            .frame(height: 8).accessibilityHidden(true)
          Text("\(format(intensityMaximum)) MET")
        }
        Text(
          days == 1
            ? "One tile per hour · Faint tiles have no recording"
            : "One tile per day · Faint tiles have no recording")
        Text("Tile intensity shows the average of recorded batch means.")
      }
      .font(.caption2).foregroundStyle(Color.secondaryInk)
    } else {
      HStack(spacing: 8) {
        Image(systemName: usesTrace ? "waveform.path" : "circle.fill").font(
          .system(size: usesTrace ? 12 : 6))
        Text(days == 1 ? "Hourly average" : "Daily average")
        Text("·")
        Text("Bar shows range")
      }
      .font(.caption2).foregroundStyle(Color.secondaryInk)
    }
  }

  @ViewBuilder private var valueAndUnit: some View {
    if selectedDate != nil && selected == nil {
      Text("No readings").font(.title2)
    } else {
      Text(format(displayedValue)).font(.system(.largeTitle, design: .rounded)).tracking(-1)
        .contentTransition(.numericText())
      Text(metric.unit).font(.subheadline).foregroundStyle(Color.secondaryInk)
    }
  }

  private var detail: String {
    if let selected {
      return
        "\(selected.start.formatted(date: .abbreviated, time: days == 1 ? .shortened : .omitted)) · \(selected.count) \(readingLabel) · \(format(selected.minimum))–\(format(selected.maximum)) \(metric.unit)"
    }
    if let selectedDate {
      return selectedDate.formatted(date: .abbreviated, time: days == 1 ? .shortened : .omitted)
    }
    if days == 1, let latest = samples.last {
      return latest.end.formatted(date: .abbreviated, time: .shortened)
    }
    return "Last \(days) days · \(samples.count.formatted()) \(readingLabel)"
  }

  private var chart: some View {
    Chart {
      if metric.kind == .activityMET {
        ForEach(timeSlots, id: \.start) { slot in
          RectangleMark(
            xStart: .value("Start", tileStart(slot)), xEnd: .value("End", tileEnd(slot)),
            yStart: .value("Base", 0), yEnd: .value("Tile", 1)
          )
          .cornerRadius(4)
          .foregroundStyle(Color.secondaryInk.opacity(0.07))
          .accessibilityHidden(true)
        }
      }
      ForEach(buckets) { bucket in
        let date = max(range.lowerBound, bucket.start)
        if metric.kind == .activityMET {
          RectangleMark(
            xStart: .value("Start", tileStart(DateInterval(start: bucket.start, end: bucket.end))),
            xEnd: .value("End", tileEnd(DateInterval(start: bucket.start, end: bucket.end))),
            yStart: .value("Base", 0), yEnd: .value("Tile", 1)
          )
          .cornerRadius(4)
          .foregroundStyle(Color.forest.opacity(0.18 + 0.82 * bucket.average / intensityMaximum))
          .accessibilityLabel(
            bucket.start.formatted(date: .abbreviated, time: days == 1 ? .shortened : .omitted)
          )
          .accessibilityValue(
            "Average \(format(bucket.average)) MET from \(bucket.count) batch means")
        } else {
          RuleMark(
            x: .value("Recorded", date),
            yStart: .value("Low", bucket.minimum), yEnd: .value("High", bucket.maximum)
          )
          .lineStyle(StrokeStyle(lineWidth: 5, lineCap: .round))
          .foregroundStyle(Color.forest.opacity(0.25))
          .accessibilityHidden(true)
          if usesTrace {
            LineMark(
              x: .value("Recorded", date), y: .value(metric.title, bucket.average),
              series: .value("Recording", lineSeries[bucket.id] ?? 0)
            )
            .interpolationMethod(.linear)
            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
            .foregroundStyle(Color.forest)
            .accessibilityHidden(true)
          }
          PointMark(x: .value("Recorded", date), y: .value(metric.title, bucket.average))
            .foregroundStyle(Color.forest).symbolSize(selected?.id == bucket.id ? 60 : 22)
            .accessibilityLabel(
              bucket.start.formatted(date: .abbreviated, time: days == 1 ? .shortened : .omitted)
            )
            .accessibilityValue(
              "Average \(format(bucket.average)) \(metric.unit), range \(format(bucket.minimum)) to \(format(bucket.maximum)), \(bucket.count) \(readingLabel)"
            )
        }
      }
      if let selected {
        RuleMark(x: .value("Selected", max(range.lowerBound, selected.start)))
          .foregroundStyle(Color.secondaryInk.opacity(0.5))
          .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
          .accessibilityHidden(true)
      }
    }
    .chartXScale(domain: range)
    .chartYScale(domain: metric.kind == .activityMET ? 0...1 : verticalRange)
    .chartXSelection(
      value: Binding(
        get: { selectedDate },
        set: { if let date = $0 { selectedDate = date } }
      )
    )
    .chartXAxis {
      AxisMarks(values: .automatic(desiredCount: 3)) {
        AxisGridLine().foregroundStyle(Color.secondaryInk.opacity(0.12))
        AxisValueLabel(format: days == 1 ? .dateTime.hour() : .dateTime.month(.abbreviated).day())
      }
    }
    .chartYAxis {
      if metric.kind != .activityMET {
        AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) {
          AxisGridLine().foregroundStyle(Color.secondaryInk.opacity(0.12))
          AxisValueLabel()
        }
      }
    }
    .frame(height: metric.kind == .activityMET ? 100 : 180)
    .id(colorScheme)
    .accessibilityLabel(
      "\(metric.title), \(metric.unit). \(days == 1 ? "Hourly" : "Daily") averages and recorded ranges."
    )
    .onChange(of: days) { _, _ in selectedDate = nil }
  }

  private func tileStart(_ slot: DateInterval) -> Date {
    let start = max(range.lowerBound, slot.start)
    let end = min(range.upperBound, slot.end)
    return start.addingTimeInterval(end.timeIntervalSince(start) * 0.06)
  }

  private func tileEnd(_ slot: DateInterval) -> Date {
    let start = max(range.lowerBound, slot.start)
    let end = min(range.upperBound, slot.end)
    return end.addingTimeInterval(-end.timeIntervalSince(start) * 0.06)
  }

  private func format(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(metric.precision)))
  }
}
