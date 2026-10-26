import Foundation

public struct MeasurementBucket: Identifiable, Sendable {
  public var id: Date { start }
  public let start: Date
  public let end: Date
  public let minimum: Double
  public let maximum: Double
  public let average: Double
  public let count: Int
}

public struct MeasurementBuckets: Sendable {
  public let values: [MeasurementBucket]

  /// Group one measurement kind at a time. Missing intervals remain absent.
  public init(
    samples: [Measurement], interval: Calendar.Component, calendar: Calendar = .current
  ) {
    precondition(interval == .hour || interval == .day, "Buckets support hours and days")
    var grouped: [Date: (end: Date, readings: [Double])] = [:]
    for sample in samples where sample.value.isFinite {
      guard let window = calendar.dateInterval(of: interval, for: sample.end) else { continue }
      grouped[window.start, default: (window.end, [])].readings.append(sample.value)
    }
    values = grouped.keys.sorted().compactMap { start in
      guard let group = grouped[start], let minimum = group.readings.min(),
        let maximum = group.readings.max()
      else { return nil }
      let count = group.readings.count
      return MeasurementBucket(
        start: start, end: group.end, minimum: minimum, maximum: maximum,
        average: group.readings.reduce(0) { $0 + $1 / Double(count) }, count: count)
    }
  }
}
