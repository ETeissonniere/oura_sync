import OuraProtocol
import SwiftUI

struct RecordedSleepSummary: View {
  let period: SleepStagePeriod
  let showSleep: () -> Void

  private var minutesAsleep: Int {
    period.epochs.filter { $0.stage != .awake }.count / 2
  }

  var body: some View {
    Surface(prominent: true) {
      Text("LATEST RECORDED SLEEP").font(.caption2.weight(.semibold)).tracking(1.5)
      Text("\(minutesAsleep / 60)h \(minutesAsleep % 60)m")
        .font(.system(.largeTitle, design: .rounded)).tracking(-1)
      Text(period.start.formatted(date: .abbreviated, time: .omitted))
        .font(.subheadline).foregroundStyle(Color.secondaryInk)
      SleepStageChart(intervals: SleepChartStyle.intervals(for: period))
      Text(
        "Time asleep across available stages. Clock times are approximate; recording may cover only part of the night."
      )
      .font(.caption).foregroundStyle(Color.secondaryInk)
      Button(action: showSleep) {
        HStack {
          Text("Explore your sleep")
          Spacer()
          Image(systemName: "arrow.right")
        }
        .font(.subheadline).frame(minHeight: 44).contentShape(Rectangle())
      }
      .buttonStyle(.plain)
    }
  }
}
