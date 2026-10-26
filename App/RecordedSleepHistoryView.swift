import OuraProtocol
import SwiftUI

struct RecordedSleepHistoryView: View {
  let periods: [SleepStagePeriod]
  let measurements: [OuraProtocol.Measurement]
  var nightlyVitals: [NightlyVitals] = []
  @State private var selectedID: String?

  private struct Recording: Identifiable {
    let id: String
    let start: Date
    let period: SleepStagePeriod?
    let vitals: NightlyVitals?
  }

  private var ordered: [Recording] {
    var matchedVitals = Set<String>()
    var recordings = periods.map { period in
      let vitals = nightlyVitals.first {
        $0.session == period.session && $0.start == period.recordedBedtime?.start
          && $0.end == period.recordedBedtime?.end
      }
      if let vitals { matchedVitals.insert(vitals.id) }
      return Recording(
        id: period.id, start: vitals?.start ?? period.start,
        period: period, vitals: vitals)
    }
    recordings += nightlyVitals.filter { !matchedVitals.contains($0.id) }.map {
      Recording(id: $0.id, start: $0.start, period: nil, vitals: $0)
    }
    return recordings.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
  }
  private var selectedIndex: Int? {
    guard !ordered.isEmpty else { return nil }
    return ordered.firstIndex {
      $0.id == selectedID || (selectedID != nil && $0.vitals?.id == selectedID)
    } ?? ordered.count - 1
  }

  var body: some View {
    if let index = selectedIndex {
      let period = ordered[index]
      if ordered.count > 1 {
        HStack {
          Button {
            selectedID = ordered[index - 1].id
          } label: {
            Image(systemName: "chevron.left").frame(width: 44, height: 44)
              .contentShape(Rectangle())
          }
          .disabled(index == 0).accessibilityLabel("Previous sleep recording")
          Spacer(minLength: 8)
          Menu {
            ForEach(ordered.reversed()) { item in
              Button {
                selectedID = item.id
              } label: {
                if item.id == period.id {
                  Label(dateLabel(item), systemImage: "checkmark")
                } else {
                  Text(dateLabel(item))
                }
              }
            }
          } label: {
            VStack(spacing: 4) {
              Text(period.start.formatted(date: .abbreviated, time: .omitted))
              Text("Recording \(index + 1) of \(ordered.count)")
                .font(.caption).foregroundStyle(Color.secondaryInk)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
          }
          .accessibilityLabel("Choose sleep recording")
          .accessibilityValue(dateLabel(period))
          Spacer(minLength: 8)
          Button {
            selectedID = ordered[index + 1].id
          } label: {
            Image(systemName: "chevron.right").frame(width: 44, height: 44)
              .contentShape(Rectangle())
          }
          .disabled(index == ordered.count - 1).accessibilityLabel("Next sleep recording")
        }
        .buttonStyle(.plain)
      }
      if let stages = period.period {
        RecordedSleepStagesView(period: stages)
      } else {
        Surface {
          Label("Awaiting sleep stages", systemImage: "moon")
            .font(.headline)
          Text(
            "Your ring has supplied a bedtime window. A sleep-stage timeline is not available for this recording yet."
          )
          .font(.subheadline).foregroundStyle(Color.secondaryInk)
        }
      }
      if let bedtime = period.period?.recordedBedtime {
        RecordedBedtimeCard(interval: bedtime)
      } else if let summary = period.vitals {
        RecordedBedtimeCard(interval: DateInterval(start: summary.start, end: summary.end))
      }
      if let summary = period.vitals {
        NightlyVitalsView(summary: summary)
      }
    } else {
      RecordedSleepView(measurements: measurements)
    }
  }

  private func dateLabel(_ period: Recording) -> String {
    period.start.formatted(date: .abbreviated, time: .shortened)
  }
}
