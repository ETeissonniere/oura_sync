import Charts
import OuraProtocol
import SwiftUI

struct SleepChartInterval: Identifiable {
  var id: Date { start }
  let stage: SleepStage
  let start: Date
  var end: Date
}

enum SleepChartStyle {
  static let stages: [SleepStage] = [.awake, .rem, .light, .deep]

  static func intervals(for period: SleepStagePeriod) -> [SleepChartInterval] {
    var runs: [SleepChartInterval] = []
    for epoch in period.epochs {
      if let last = runs.last, last.stage == epoch.stage, last.end == epoch.start {
        runs[runs.count - 1].end = epoch.end
      } else {
        runs.append(SleepChartInterval(stage: epoch.stage, start: epoch.start, end: epoch.end))
      }
    }
    return runs
  }

  static func level(_ stage: SleepStage) -> Double {
    switch stage {
    case .deep: 0
    case .light: 1
    case .rem: 2
    case .awake: 3
    }
  }

  static func label(_ stage: SleepStage) -> String {
    stage == .rem ? "REM" : stage.rawValue.capitalized
  }

  static func color(_ stage: SleepStage, scheme: ColorScheme) -> Color {
    switch stage {
    case .awake: Color(red: 0.95, green: 0.49, blue: 0.46)
    case .rem: Color(red: 0.25, green: 0.75, blue: 0.86)
    case .light: Color(red: 0.22, green: 0.48, blue: 0.94)
    case .deep:
      scheme == .dark
        ? Color(red: 0.44, green: 0.39, blue: 0.85)
        : Color(red: 0.30, green: 0.27, blue: 0.67)
    }
  }
}

struct SleepStageChart: View {
  let intervals: [SleepChartInterval]
  var timeZone: TimeZone = .current
  var accessibilitySummary = "Ring sleep stages. Clock times are approximate."
  @Environment(\.colorScheme) private var colorScheme
  @ScaledMetric(relativeTo: .caption) private var chartHeight = 240.0

  private struct Transition: Identifiable {
    var id: Date { time }
    let time: Date
    let from: SleepStage
    let to: SleepStage
  }

  private var transitions: [Transition] {
    zip(intervals, intervals.dropFirst()).compactMap { previous, next in
      // Connect only touching recorded intervals; a gap is never a transition.
      guard previous.end == next.start, previous.stage != next.stage else { return nil }
      return Transition(time: next.start, from: previous.stage, to: next.stage)
    }
  }

  private var timeFormat: Date.FormatStyle {
    Date.FormatStyle(date: .omitted, time: .shortened, timeZone: timeZone)
  }

  private var timeTicks: [Date] {
    guard let first = intervals.first, let last = intervals.last else { return [] }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    guard var hour = calendar.dateInterval(of: .hour, for: first.start)?.start else { return [] }
    var ticks: [Date] = []
    while hour <= last.end {
      if hour >= first.start, calendar.component(.hour, from: hour).isMultiple(of: 2) {
        ticks.append(hour)
      }
      guard let next = calendar.date(byAdding: .hour, value: 1, to: hour), next > hour else {
        break
      }
      hour = next
    }
    return ticks.count >= 2 ? ticks : [first.start, last.end]
  }

  var body: some View {
    Chart {
      ForEach(SleepChartStyle.stages, id: \.self) { stage in
        RuleMark(y: .value("Lane", SleepChartStyle.level(stage) + 0.5))
          .foregroundStyle(Color.secondaryInk.opacity(0.2))
          .lineStyle(StrokeStyle(lineWidth: 0.7))
          .accessibilityHidden(true)
      }
      RuleMark(y: .value("Bottom", -0.5))
        .foregroundStyle(Color.secondaryInk.opacity(0.2))
        .lineStyle(StrokeStyle(lineWidth: 0.7)).accessibilityHidden(true)
      ForEach(transitions) { transition in
        RectangleMark(
          x: .value("Transition", transition.time),
          yStart: .value(
            "From",
            min(SleepChartStyle.level(transition.from), SleepChartStyle.level(transition.to)) - 0.13
          ),
          yEnd: .value(
            "To",
            max(SleepChartStyle.level(transition.from), SleepChartStyle.level(transition.to)) - 0.13
          ), width: .fixed(1.5)
        )
        .cornerRadius(0.75)
        .foregroundStyle(SleepChartStyle.color(transition.to, scheme: colorScheme).opacity(0.12))
        .accessibilityHidden(true)
      }
      ForEach(intervals) { interval in
        RectangleMark(
          xStart: .value("Start", interval.start), xEnd: .value("End", interval.end),
          yStart: .value("Stage lower", SleepChartStyle.level(interval.stage) - 0.37),
          yEnd: .value("Stage upper", SleepChartStyle.level(interval.stage) + 0.11)
        )
        .cornerRadius(6)
        .foregroundStyle(SleepChartStyle.color(interval.stage, scheme: colorScheme))
        .accessibilityLabel(SleepChartStyle.label(interval.stage))
        .accessibilityValue(
          "\(interval.start.formatted(timeFormat)), \(Duration.seconds(interval.end.timeIntervalSince(interval.start)).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide)))"
        )
      }
    }
    .chartYScale(domain: -0.5...3.5)
    .chartXAxis {
      AxisMarks(values: timeTicks) {
        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.7, dash: [2, 3]))
          .foregroundStyle(Color.secondaryInk.opacity(0.2))
        AxisValueLabel(format: timeFormat).font(.caption2)
      }
    }
    .chartYAxis(.hidden)
    .chartOverlay { proxy in
      GeometryReader { geometry in
        if let plot = proxy.plotFrame {
          let frame = geometry[plot]
          VStack(spacing: 0) {
            ForEach(SleepChartStyle.stages, id: \.self) { stage in
              Text(SleepChartStyle.label(stage)).font(.caption)
                .foregroundStyle(Color.secondaryInk)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, 5).padding(.leading, 4)
            }
          }
          .frame(width: frame.width, height: frame.height)
          .position(x: frame.midX, y: frame.midY)
          .allowsHitTesting(false).accessibilityHidden(true)
        }
      }
    }
    .frame(height: chartHeight)
    .id(colorScheme)
    .accessibilityLabel(accessibilitySummary)
  }
}
