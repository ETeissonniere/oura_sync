import Charts
import OuraProtocol
import SwiftUI

struct SleepTotal: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("TIME ASLEEP").font(.caption2.weight(.semibold)).tracking(1.5)
      Text(PreviewData.duration(PreviewData.asleepMinutes))
        .font(.system(.largeTitle, design: .rounded).weight(.regular)).tracking(-1)
      Text(
        "\(PreviewData.asleepMinutes - PreviewData.averageSleepMinutes) minutes more than your 7-day average"
      )
      .font(.caption).foregroundStyle(Color.secondaryInk)
    }
    .accessibilityElement(children: .combine)
  }
}

struct SleepTimeline: View {
  private var intervals: [SleepChartInterval] {
    let bedtime = Date(timeIntervalSince1970: Double(PreviewData.bedtimeMinute) * 60)
    return PreviewData.stages.compactMap { segment in
      guard let stage = SleepStage(rawValue: segment.stage.lowercased()) else { return nil }
      return SleepChartInterval(
        stage: stage, start: bedtime.addingTimeInterval(Double(segment.startMinute) * 60),
        end: bedtime.addingTimeInterval(Double(segment.endMinute) * 60))
    }
  }

  var body: some View {
    VStack(spacing: 10) {
      SleepStageChart(intervals: intervals, timeZone: .gmt, approximateTimes: false)
        .accessibilityLabel(
          "Illustrative sleep stages from \(PreviewData.bedtimeLabel) to \(PreviewData.wakeTimeLabel)"
        )
      HStack {
        Text(PreviewData.bedtimeLabel)
        Spacer()
        Text(PreviewData.wakeTimeLabel)
      }
      .font(.caption2).foregroundStyle(Color.secondaryInk)
    }
  }
}

struct SleepView: View {
  @Environment(RingCoordinator.self) private var ring
  @Environment(\.colorScheme) private var colorScheme
  let preview: Bool
  var body: some View {
    PageHeading(
      title: "A closer look\nat your night.", subtitle: preview ? "Sample night" : "Sleep")
    if preview {
      Surface(prominent: true) {
        SleepTotal()
        SleepTimeline()
      }
      Text("Sleep stages").font(.headline)
      VStack(spacing: 0) {
        ForEach(SleepChartStyle.stages, id: \.self) { stage in
          HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 3).fill(
              SleepChartStyle.color(stage, scheme: colorScheme)
            )
            .frame(width: 12, height: 12).accessibilityHidden(true)
            Text(SleepChartStyle.label(stage))
            Spacer()
            Text(PreviewData.duration(PreviewData.minutes(in: SleepChartStyle.label(stage))))
          }
          .font(.subheadline).padding(.vertical, 12).accessibilityElement(children: .combine)
          if stage != .deep { Divider() }
        }
      }
      Text("Stages reported by your ring. Gaps in recording stay visible.")
        .font(.caption).foregroundStyle(Color.secondaryInk)
      Surface {
        HStack {
          Text("Overnight heart rate").font(.headline)
          Spacer()
          Text("bpm").font(.caption)
        }
        Chart(PreviewData.heartRate) { point in
          LineMark(x: .value("Hours since bedtime", point.hour), y: .value("Heart rate", point.bpm))
            .foregroundStyle(Color.forest)
        }
        .chartYScale(domain: 45...65)
        .chartXAxisLabel("Hours since bedtime")
        .frame(height: 160)
      }
    } else if !ring.sleepPeriods.isEmpty || ring.measurements.contains(where: { $0.kind == .inBed })
    {
      RecordedSleepHistoryView(
        periods: ring.sleepPeriods, measurements: ring.measurements,
        nightlyVitals: ring.nightlyVitals)
    } else {
      EmptyMeasurements(
        title: "A night worth understanding.",
        message:
          "After your first overnight recording, your sleep timeline and overnight heart rate will appear here."
      )
    }
  }
}
