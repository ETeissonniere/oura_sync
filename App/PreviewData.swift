import Foundation

// Preview values never enter the ring store or HealthKit export path.
enum PreviewData {
  struct HeartRate: Identifiable {
    let id: Int
    let hour: Double
    let bpm: Double
  }

  struct SleepSegment: Identifiable {
    let id: Int
    let startMinute: Int
    let endMinute: Int
    let stage: String

    var start: Double { Double(startMinute) / 60 }
    var end: Double { Double(endMinute) / 60 }
    var durationMinutes: Int { endMinute - startMinute }
  }

  static let heartRate: [HeartRate] = [58, 55, 56, 53, 54, 51, 52, 50, 52, 53, 51, 54]
    .enumerated().map { HeartRate(id: $0.offset, hour: Double($0.offset) * 0.65, bpm: $0.element) }

  static let stages: [SleepSegment] = {
    let values: [(stage: String, minutes: Int)] = [
      ("Light", 42), ("Deep", 48), ("Light", 38), ("REM", 28),
      ("Light", 44), ("Deep", 36), ("Light", 52), ("REM", 36),
      ("Awake", 16), ("Light", 48), ("REM", 44), ("Light", 36),
    ]
    var elapsed = 0
    return values.enumerated().map {
      let start = elapsed
      elapsed += $0.element.minutes
      return SleepSegment(
        id: $0.offset, startMinute: start, endMinute: elapsed, stage: $0.element.stage)
    }
  }()

  static let bedtimeMinute = 23 * 60 + 14
  static let averageSleepMinutes = 7 * 60 + 4
  static var totalMinutes: Int { stages.reduce(0) { $0 + $1.durationMinutes } }
  static var asleepMinutes: Int {
    stages.filter { $0.stage != "Awake" }.reduce(0) { $0 + $1.durationMinutes }
  }
  static var bedtimeLabel: String { clockTime(bedtimeMinute) }
  static var wakeTimeLabel: String { clockTime(bedtimeMinute + totalMinutes) }

  static func minutes(in stage: String) -> Int {
    stages.filter { $0.stage == stage }.reduce(0) { $0 + $1.durationMinutes }
  }

  static func duration(_ minutes: Int) -> String {
    let hours = minutes / 60
    return hours == 0 ? "\(minutes)m" : "\(hours)h \(minutes % 60)m"
  }

  private static func clockTime(_ minutes: Int) -> String {
    // These are illustrative clock labels, independent of the viewer's date or
    // daylight-saving transition. The locale still controls 12/24-hour display.
    Date(timeIntervalSince1970: Double(minutes % (24 * 60)) * 60)
      .formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: .gmt))
  }
}
