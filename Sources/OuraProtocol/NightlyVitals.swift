import Foundation

public struct NightlyVital: Sendable, Equatable {
  public let average: Double
  public let minimum: Double
  public let maximum: Double
  public let count: Int
}

public struct NightlyVitals: Identifiable, Sendable, Equatable {
  public let id: String
  public let session: UUID
  public let start: Date
  public let end: Date
  public let heartRate: NightlyVital?
  public let hrv: NightlyVital?
  public let respiratoryRate: NightlyVital?
  public let oxygenSaturation: NightlyVital?
  public let skinTemperature: Double?

  /// Calculate one ring session at a time; reset epochs must never share measurements.
  public static func calculate(measurements: [Measurement], session: UUID) -> [Self] {
    let valid = measurements.filter {
      $0.start.timeIntervalSinceReferenceDate.isFinite
        && $0.end.timeIntervalSinceReferenceDate.isFinite && $0.end >= $0.start
    }
    let bedtimes = valid.filter {
      $0.kind == .inBed && $0.end > $0.start && $0.end.timeIntervalSince($0.start) <= 86_400
        && $0.value.isFinite && $0.value > 0
    }
    let groupedWindows = Dictionary(grouping: bedtimes) {
      DateInterval(start: $0.start, end: $0.end)
    }
    let windows = groupedWindows.keys.sorted {
      $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start
    }
    return windows.compactMap { window in
      guard let bedtime = groupedWindows[window]?.min(by: { $0.id < $1.id }) else { return nil }
      let contained = valid.filter { $0.start >= window.start && $0.end <= window.end }
      return Self(
        id: "\(session.uuidString).night.\(bedtime.id)", session: session,
        start: window.start, end: window.end,
        heartRate: summarize(.heartRate, samples: contained),
        hrv: summarize(.hrvRMSSD, samples: contained),
        respiratoryRate: summarize(.respiratoryRate, samples: contained),
        oxygenSaturation: summarize(.oxygenSaturation, samples: contained),
        skinTemperature: NightlyTemperature.calculate(samples: contained))
    }
  }

  private static func summarize(_ kind: MeasurementKind, samples: [Measurement]) -> NightlyVital? {
    let eligible = samples.filter {
      guard $0.kind == kind else { return false }
      if kind == .heartRate || kind == .hrvRMSSD {
        return abs($0.end.timeIntervalSince($0.start) - 300) < 0.001
      }
      return true
    }
    let grouped = Dictionary(grouping: eligible) { DateInterval(start: $0.start, end: $0.end) }
    let intervals = grouped.keys.sorted {
      $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start
    }
    let values = intervals.compactMap { interval -> Double? in
      guard let readings = grouped[interval], let value = readings.first?.value,
        value.isFinite, value > 0,
        readings.allSatisfy({ $0.value == value })
      else { return nil }
      // A conflicting interval has no authoritative winner; duplicate deliveries
      // must not change either the value or its weight in the nightly summary.
      return value
    }
    guard let minimum = values.min(), let maximum = values.max() else { return nil }
    let count = values.count
    return NightlyVital(
      average: values.reduce(0) { $0 + $1 / Double(count) }, minimum: minimum,
      maximum: maximum, count: count)
  }
}
