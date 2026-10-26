import Charts
import OuraProtocol
import SwiftUI

struct HeartSummaryView: View {
  let measurements: [OuraProtocol.Measurement]
  let days: Int
  let range: ClosedRange<Date>
  @State private var showRecordings = false
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  private var hrvLayout: AnyLayout {
    dynamicTypeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
      : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
  }

  private var heart: [OuraProtocol.Measurement] {
    measurements.filter { $0.kind == .heartRate }.sorted { $0.end < $1.end }
  }
  private var hrv: [OuraProtocol.Measurement] {
    measurements.filter { $0.kind == .hrvRMSSD }.sorted { $0.end < $1.end }
  }

  var body: some View {
    Surface(prominent: true) {
      HStack {
        Label("Heart rate", systemImage: "heart.fill").font(.headline)
        Spacer()
        Text(days == 1 ? "Past day" : "Last \(days) days")
          .font(.caption).foregroundStyle(Color.secondaryInk)
      }
      if let latest = heart.last {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text(number(latest.value)).font(.system(.largeTitle, design: .rounded))
          Text("bpm").font(.subheadline).foregroundStyle(Color.secondaryInk)
        }
        .accessibilityElement(children: .combine)
        Text("Latest · \(latest.end.formatted(date: .abbreviated, time: .shortened))")
          .font(.caption).foregroundStyle(Color.secondaryInk)
        HeartRecordingChart(
          samples: heart, measurements: measurements, range: range, kind: .heartRate, days: days,
          overview: true)
        ViewThatFits(in: .horizontal) {
          HStack(alignment: .top, spacing: 24) { extremes }
          VStack(alignment: .leading, spacing: 14) { extremes }
        }
      } else {
        Text("Awaiting heart-rate recordings").font(.subheadline)
      }
      Divider()
      hrvLayout {
        VStack(alignment: .leading, spacing: 4) {
          Text("Heart rate variability").font(.subheadline.weight(.medium))
          Text("Beat-to-beat variation · RMSSD").font(.caption).foregroundStyle(Color.secondaryInk)
        }
        if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 12) }
        if let latest = hrv.last {
          Text("\(number(latest.value)) ms").font(.title3)
        }
      }
      if let latest = hrv.last {
        Text("Latest HRV · \(latest.end.formatted(date: .abbreviated, time: .shortened))")
          .font(.caption).foregroundStyle(Color.secondaryInk)
      } else {
        Text("Awaiting HRV recordings")
          .font(.subheadline).foregroundStyle(Color.secondaryInk)
        Text("Your ring hasn’t supplied HRV readings for this period yet.")
          .font(.caption).foregroundStyle(Color.secondaryInk)
      }
      Button {
        showRecordings = true
      } label: {
        HStack {
          Text("Explore heart recordings")
          Spacer()
          Image(systemName: "arrow.right")
        }
        .font(.subheadline.weight(.medium)).frame(minHeight: 44).contentShape(Rectangle())
      }
      .buttonStyle(.plain)
    }
    .sheet(isPresented: $showRecordings) {
      HeartRecordingsView(measurements: measurements, days: days, range: range)
    }
  }

  @ViewBuilder private var extremes: some View {
    if let low = heart.min(by: { $0.value < $1.value }),
      let high = heart.max(by: { $0.value < $1.value })
    {
      extreme("Lowest recorded", sample: low)
      extreme("Highest recorded", sample: high)
    }
  }

  private func extreme(_ title: String, sample: OuraProtocol.Measurement) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.caption).foregroundStyle(Color.secondaryInk)
      Text("\(number(sample.value)) bpm").font(.title3)
      Text(sample.end.formatted(date: days == 1 ? .omitted : .abbreviated, time: .shortened))
        .font(.caption2).foregroundStyle(Color.secondaryInk)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }

  private func number(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(0)))
  }
}

private struct HeartRecordingsView: View {
  let measurements: [OuraProtocol.Measurement]
  let days: Int
  let range: ClosedRange<Date>
  @State private var kind: MeasurementKind = .heartRate
  @State private var selectedDate: Date?
  @Environment(\.dismiss) private var dismiss

  private var samples: [OuraProtocol.Measurement] {
    measurements.filter { $0.kind == kind }.sorted { $0.end < $1.end }
  }
  private var selected: OuraProtocol.Measurement? {
    guard let selectedDate else { return nil }
    return samples.min {
      abs($0.end.timeIntervalSince(selectedDate)) < abs($1.end.timeIntervalSince(selectedDate))
    }
  }
  private var unit: String { kind == .heartRate ? "bpm" : "ms" }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          Picker("Heart measurement", selection: $kind) {
            Text("Heart rate").tag(MeasurementKind.heartRate)
            Text("HRV").tag(MeasurementKind.hrvRMSSD)
          }.pickerStyle(.segmented)
          if samples.isEmpty {
            EmptyMeasurements(
              title: kind == .hrvRMSSD
                ? "Awaiting HRV recordings" : "Awaiting heart-rate recordings",
              message:
                "Your ring’s measurements will appear here after they are recorded and synced.")
          } else {
            Surface(prominent: true) {
              Text(selected == nil ? "RECORDED RANGE" : "SELECTED RECORDING")
                .font(.caption2.weight(.semibold)).tracking(1.3)
              if let selected {
                Text("\(number(selected.value)) \(unit)").font(.largeTitle)
                Text(selected.end.formatted(date: .abbreviated, time: .shortened))
                  .font(.caption).foregroundStyle(Color.secondaryInk)
                Text(readingType(selected)).font(.caption).foregroundStyle(Color.secondaryInk)
              } else if let low = samples.map(\.value).min(), let high = samples.map(\.value).max()
              {
                Text("\(number(low))–\(number(high)) \(unit)").font(.largeTitle)
                Text(
                  "\(samples.count.formatted()) recordings · \(days == 1 ? "Past day" : "Last \(days) days")"
                )
                .font(.caption).foregroundStyle(Color.secondaryInk)
              }
              HeartRecordingChart(
                samples: samples, measurements: measurements, range: range,
                kind: kind, days: days, selectedDate: $selectedDate)
              if selectedDate != nil {
                Button("Show recorded range") { selectedDate = nil }.font(.subheadline)
              } else {
                Text("Touch the chart to inspect the nearest recorded reading.")
                  .font(.caption).foregroundStyle(Color.secondaryInk)
              }
            }
            DisclosureGroup("Understand these recordings") {
              VStack(alignment: .leading, spacing: 10) {
                if kind == .heartRate {
                  let shortCount = samples.filter { $0.start == $0.end }.count
                  Text(
                    "\(shortCount.formatted()) short recordings · \((samples.count - shortCount).formatted()) five-minute averages"
                  )
                  Text(
                    "Short recordings combine quality-accepted beats from one ring recording. Longer marks show the time covered by five-minute averages."
                  )
                } else {
                  Text(
                    "RMSSD measures beat-to-beat variation in milliseconds. These are the ring’s five-minute HRV averages."
                  )
                }
                Text(
                  "Bedtime shading follows the ring’s detected bedtime windows, which can include time awake. Activity, stress and restorative states are not classified here."
                )
              }
              .font(.subheadline).foregroundStyle(Color.secondaryInk).padding(.top, 8)
            }
          }
        }
        .padding(24)
      }
      .background(Color.paper).foregroundStyle(Color.ink)
      .navigationTitle("Heart recordings").navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
      .onChange(of: kind) { _, _ in selectedDate = nil }
    }
    .tint(.forest)
  }

  private func number(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(0)))
  }

  private func readingType(_ sample: OuraProtocol.Measurement) -> String {
    if kind == .hrvRMSSD { return "Five-minute RMSSD average" }
    return sample.start == sample.end ? "Short heart-rate recording" : "Five-minute average"
  }
}

private struct HeartRecordingChart: View {
  let samples: [OuraProtocol.Measurement]
  let measurements: [OuraProtocol.Measurement]
  let range: ClosedRange<Date>
  let kind: MeasurementKind
  let days: Int
  var overview = false
  var selectedDate: Binding<Date?>?
  @Environment(\.colorScheme) private var colorScheme

  private var buckets: [MeasurementBucket] {
    guard showsSummary else { return [] }
    return MeasurementBuckets(samples: samples, interval: usesHourlyBuckets ? .hour : .day).values
  }

  private var showsSummary: Bool { overview || days > 1 }
  private var usesHourlyBuckets: Bool { days == 1 || (!overview && days <= 7) }

  private var chartLabel: String {
    let metric = kind == .heartRate ? "Recorded heart rate" : "Recorded HRV"
    if !showsSummary { return "\(metric), without hourly averaging" }
    return "\(metric), \(usesHourlyBuckets ? "hourly" : "daily") averages and recorded ranges"
  }

  private var verticalRange: ClosedRange<Double> {
    let low = samples.map(\.value).min() ?? 0
    let high = samples.map(\.value).max() ?? 1
    let padding = max(3, (high - low) * 0.15)
    return max(0, low - padding)...(high + padding)
  }

  private var bedtimes: [DateInterval] {
    let windows = measurements.filter {
      $0.kind == .inBed && $0.end > range.lowerBound && $0.start < range.upperBound
    }
    .map {
      DateInterval(start: max(range.lowerBound, $0.start), end: min(range.upperBound, $0.end))
    }
    .sorted { $0.start < $1.start }
    var merged: [DateInterval] = []
    for window in windows {
      if let last = merged.last, last.end >= window.start {
        merged[merged.count - 1] = DateInterval(start: last.start, end: max(last.end, window.end))
      } else {
        merged.append(window)
      }
    }
    return merged
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Chart {
        ForEach(bedtimes, id: \.start) { bedtime in
          RectangleMark(
            xStart: .value("Bedtime start", bedtime.start),
            xEnd: .value("Bedtime end", bedtime.end),
            yStart: .value("Low", verticalRange.lowerBound),
            yEnd: .value("High", verticalRange.upperBound)
          )
          .foregroundStyle(Color.indigo.opacity(0.08)).accessibilityHidden(true)
        }
        if showsSummary {
          ForEach(buckets) { bucket in
            let date = max(range.lowerBound, bucket.start)
            RuleMark(
              x: .value("Recorded", date), yStart: .value("Lowest", bucket.minimum),
              yEnd: .value("Highest", bucket.maximum)
            )
            .lineStyle(StrokeStyle(lineWidth: overview ? 2 : 5, lineCap: .round))
            .foregroundStyle(Color.forest.opacity(overview ? 0.16 : 0.25)).accessibilityHidden(true)
            PointMark(x: .value("Recorded", date), y: .value("Average", bucket.average))
              .symbolSize(overview ? 14 : 20).foregroundStyle(Color.forest)
              .accessibilityLabel(
                bucket.start.formatted(
                  date: .abbreviated, time: usesHourlyBuckets ? .shortened : .omitted)
              )
              .accessibilityValue(
                "Average \(bucket.average.formatted(.number.precision(.fractionLength(0)))), recorded range \(bucket.minimum.formatted(.number.precision(.fractionLength(0)))) to \(bucket.maximum.formatted(.number.precision(.fractionLength(0)))) \(kind == .heartRate ? "bpm" : "ms"), \(bucket.count) readings"
              )
          }
        } else {
          ForEach(samples) { sample in
            if sample.start < sample.end {
              RuleMark(
                xStart: .value("Start", max(range.lowerBound, sample.start)),
                xEnd: .value("End", sample.end),
                y: .value("Recorded value", sample.value)
              )
              .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round))
              .foregroundStyle(Color.forest.opacity(0.75))
              .accessibilityLabel(sample.end.formatted(date: .abbreviated, time: .shortened))
              .accessibilityValue(
                "\(sample.value.formatted(.number.precision(.fractionLength(0)))) \(kind == .heartRate ? "bpm" : "ms"), five-minute average"
              )
            } else {
              PointMark(
                x: .value("Recorded", sample.end), y: .value("Recorded value", sample.value)
              )
              .symbolSize(18).foregroundStyle(Color.forest)
              .accessibilityLabel(sample.end.formatted(date: .abbreviated, time: .shortened))
              .accessibilityValue(
                "\(sample.value.formatted(.number.precision(.fractionLength(0)))) bpm, short recording"
              )
            }
          }
        }
        if !overview, let date = selectedDate?.wrappedValue,
          let sample = samples.min(by: {
            abs($0.end.timeIntervalSince(date)) < abs($1.end.timeIntervalSince(date))
          })
        {
          RuleMark(x: .value("Selected", sample.end))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .foregroundStyle(Color.secondaryInk.opacity(0.5)).accessibilityHidden(true)
          PointMark(x: .value("Selected", sample.end), y: .value("Selected value", sample.value))
            .symbolSize(60).foregroundStyle(Color.forest).accessibilityHidden(true)
        }
      }
      .chartXScale(domain: range).chartYScale(domain: verticalRange)
      .chartXSelection(
        value: Binding(
          get: { selectedDate?.wrappedValue },
          set: { if let date = $0 { selectedDate?.wrappedValue = date } })
      )
      .chartXAxis {
        AxisMarks(values: .automatic(desiredCount: 3)) {
          AxisGridLine().foregroundStyle(Color.secondaryInk.opacity(0.12))
          AxisValueLabel(
            format: days <= 1
              ? .dateTime.hour() : .dateTime.month(.abbreviated).day())
        }
      }
      .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
      .frame(height: overview ? 150 : 180).id(colorScheme)
      .accessibilityLabel(chartLabel)
      HStack(spacing: 8) {
        if showsSummary {
          Image(systemName: "circle.fill").font(.system(size: 5))
          Text(usesHourlyBuckets ? "Hourly average" : "Daily average")
          Text("·")
          Text("Bars show recorded range")
        } else {
          if kind == .heartRate {
            Image(systemName: "circle.fill").font(.system(size: 5))
            Text("Short recordings")
          }
          Image(systemName: "minus").font(.caption2)
          Text("5-min averages")
        }
      }.font(.caption2).foregroundStyle(Color.secondaryInk)
      if !bedtimes.isEmpty {
        Label("Shading: detected bedtime", systemImage: "moon.fill")
          .font(.caption2).foregroundStyle(Color.secondaryInk)
      }
    }
  }
}
