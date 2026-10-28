import Charts
import OuraProtocol
import SwiftUI

struct RecordedVitalsView: View {
  let measurements: [OuraProtocol.Measurement]
  var days = 1

  var body: some View {
    let now = Date.now
    let start = Calendar.current.date(byAdding: .day, value: -days, to: now) ?? now
    let available = measurements.filter { $0.end >= start && $0.end <= now }
    let groups = Dictionary(grouping: available, by: \.kind)
    if groups[.heartRate]?.isEmpty == false || groups[.hrvRMSSD]?.isEmpty == false {
      HeartSummaryView(measurements: available, days: days, range: start...now)
    }
    if days == 1, MetricPresentation.all.contains(where: { groups[$0.kind]?.isEmpty == false }) {
      let overnight: [(MeasurementKind, String)] = [
        (.hrvRMSSD, "HRV"), (.skinTemperature, "Sleeping temperature"),
        (.oxygenSaturation, "Blood oxygen"), (.respiratoryRate, "Breathing rate"),
      ]
      let missing = overnight.filter { groups[$0.0]?.isEmpty != false }.map(\.1)
      if !missing.isEmpty {
        Surface {
          Label("Awaiting overnight readings", systemImage: "moon")
            .font(.headline)
          Text(missing.joined(separator: " · "))
            .font(.subheadline).foregroundStyle(Color.secondaryInk)
          Text(
            "These measurements usually come from sleep. Wear your ring tonight, then sync in the morning. They’ll appear when your ring supplies valid recordings."
          )
          .font(.subheadline).foregroundStyle(Color.secondaryInk)
        }
      }
    }
    ForEach(MetricPresentation.all.filter { $0.kind != .heartRate && $0.kind != .hrvRMSSD }) {
      metric in
      if let samples = groups[metric.kind], !samples.isEmpty {
        MetricChartCard(metric: metric, samples: samples, days: days, range: start...now)
      }
    }
    if MetricPresentation.all.allSatisfy({ groups[$0.kind]?.isEmpty != false }) {
      EmptyMeasurements(
        title: "No readings in this period.",
        message:
          "Measurements appear after your ring records and syncs them. Missing recordings stay empty."
      )
    }
    Text("Charts use available recordings. Missing hours and days are left empty.")
      .font(.caption).foregroundStyle(Color.secondaryInk)
  }
}

struct RecordedSleepView: View {
  let measurements: [OuraProtocol.Measurement]
  private var intervals: [OuraProtocol.Measurement] {
    measurements.filter { $0.kind == .inBed }.sorted { $0.start > $1.start }
  }
  var body: some View {
    if let last = intervals.first {
      RecordedBedtimeCard(interval: DateInterval(start: last.start, end: last.end))
      if intervals.count > 1 {
        Text("Recent nights").font(.headline)
        ForEach(Array(intervals.dropFirst().prefix(6))) { interval in
          DetailRow(
            title: interval.start.formatted(date: .abbreviated, time: .omitted),
            value:
              "\(interval.start.formatted(date: .omitted, time: .shortened)) – \(interval.end.formatted(date: .omitted, time: .shortened))"
          )
        }
      }
    }
  }
}

struct RecordedBedtimeCard: View {
  let interval: DateInterval

  var body: some View {
    Surface(prominent: true) {
      Text("DETECTED BEDTIME").font(.caption2.weight(.semibold)).tracking(1.5)
      Text(interval.start.formatted(date: .abbreviated, time: .shortened)).font(.title2)
      Text("to \(interval.end.formatted(date: .abbreviated, time: .shortened))")
        .font(.subheadline).foregroundStyle(Color.secondaryInk)
      Text(
        "This is the ring’s detected bedtime window. It includes any awake time and is not a measurement of time asleep."
      )
      .font(.caption).foregroundStyle(Color.secondaryInk)
    }
  }
}

struct RecordedSleepStagesView: View {
  let period: SleepStagePeriod
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    Surface(prominent: true) {
      Text("RECORDED SLEEP").font(.caption2.weight(.semibold)).tracking(1.5)
      Text(duration(period.epochs.filter { $0.stage != .awake }.count))
        .font(.largeTitle).tracking(-1)
      Text(period.start.formatted(date: .abbreviated, time: .omitted))
        .font(.subheadline).foregroundStyle(Color.secondaryInk)
      Text("Across the available stage recording")
        .font(.caption).foregroundStyle(Color.secondaryInk)
      SleepStageChart(
        intervals: SleepChartStyle.intervals(for: period), timeRange: period.start...period.end,
        accessibilitySummary: period.timing == .anchoredToSleepSummary
          ? "Ring sleep stages, timed from the ring’s sleep summary."
          : "Ring sleep stages. Clock times are approximate.")
      if period.unrecordedTail > 0 {
        Text(
          "\(Int(period.unrecordedTail / 60)) min at the end have no recorded stages. This gap stays blank and is not exported to Apple Health."
        )
        .font(.caption).foregroundStyle(Color.secondaryInk)
      }
      ForEach(SleepChartStyle.stages, id: \.self) { stage in
        HStack(spacing: 10) {
          RoundedRectangle(cornerRadius: 3).fill(SleepChartStyle.color(stage, scheme: colorScheme))
            .frame(width: 12, height: 12).accessibilityHidden(true)
          Text(SleepChartStyle.label(stage))
          Spacer()
          Text(duration(count(stage)))
        }
        .font(.subheadline).accessibilityElement(children: .combine)
      }
      Text(
        period.timing == .anchoredToSleepSummary
          ? "Stages reported by your ring, timed from its sleep summary. Complete recordings can sync to Apple Health when sleep access is allowed."
          : "Stages reported by your ring. Clock times are estimated from when its analysis finished; this recording may cover only part of your night."
      )
      .font(.caption).foregroundStyle(Color.secondaryInk)
    }
  }

  private func count(_ stage: SleepStage) -> Int {
    period.epochs.filter { $0.stage == stage }.count
  }

  private func duration(_ epochs: Int) -> String {
    let minutes = epochs / 2
    return "\(minutes / 60)h \(minutes % 60)m"
  }
}
