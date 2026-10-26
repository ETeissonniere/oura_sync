import Foundation

public enum NightlyTemperature {
  /// Reduce sleep-temperature samples already selected for one night.
  public static func calculate(samples: [Measurement]) -> Double? {
    let grouped = Dictionary(
      grouping: samples.filter {
        $0.kind == .skinTemperature && $0.end.timeIntervalSinceReferenceDate.isFinite
      }, by: \.end)
    var previous: Date?
    var filter = [Int](repeating: 0, count: 7)
    var count = 0
    var minimum = Int.max
    var maximum = 0
    var windowMaxima: [Int] = []

    func reset() {
      filter = [Int](repeating: 0, count: 7)
      count = 0
      minimum = Int.max
      maximum = 0
    }

    for date in grouped.keys.sorted() {
      guard let readings = grouped[date], let first = readings.first,
        first.value.isFinite, first.value > 0,
        readings.allSatisfy({ $0.value == first.value }),
        (1...Double(UInt16.max)).contains((first.value * 100).rounded())
      else {
        previous = nil
        reset()
        continue
      }
      // Missing or conflicting observations must not become adjacent samples in
      // the native seven-sample filter or thirty-sample windows.
      if let previous, abs(date.timeIntervalSince(previous) - 30) > 0.001 { reset() }
      previous = date
      filter[count % 7] = Int((first.value * 100).rounded())
      let median = filter.sorted()[3]
      if median != 0 {
        minimum = min(minimum, median)
        maximum = max(maximum, median)
      }
      count += 1
      if count % 30 == 0 {
        if maximum > 0, maximum >= minimum, maximum - minimum < 250 {
          windowMaxima.append(maximum)
        }
        minimum = Int.max
        maximum = 0
      }
    }
    guard windowMaxima.count >= 4, let nightly = windowMaxima.min() else { return nil }
    return Double(nightly) / 100
  }
}
