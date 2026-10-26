import Foundation
import Testing

@testable import OuraProtocol

private func temperatures(_ values: [Double], offset: TimeInterval = 0) -> [OuraProtocol
  .Measurement]
{
  values.enumerated().map { index, value in
    let date = Date(timeIntervalSince1970: 1_790_000_000 + offset + Double(index) * 30)
    return OuraProtocol.Measurement(
      id: "temperature.\(offset).\(index)", kind: .skinTemperature,
      start: date, end: date, value: value)
  }
}

@Test func nightlyTemperatureNeedsFourCompleteWindows() {
  #expect(
    NightlyTemperature.calculate(samples: temperatures(Array(repeating: 35, count: 120))) == 35)
  #expect(
    NightlyTemperature.calculate(samples: temperatures(Array(repeating: 35, count: 119))) == nil)
}

@Test func nightlyTemperatureUsesMinimumOfStableWindowMaxima() {
  let values = Array(repeating: 35.0, count: 60) + Array(repeating: 34.0, count: 60)
  #expect(NightlyTemperature.calculate(samples: temperatures(values)) == 34)
}

@Test func temperatureRangeGateRejectsExactlyTwoPointFiveDegrees() {
  // The first three windows pass; the fourth contains both plateaus after filtering.
  let values = Array(repeating: 35.0, count: 105) + Array(repeating: 37.5, count: 15)
  #expect(NightlyTemperature.calculate(samples: temperatures(values)) == nil)
  let below = Array(repeating: 35.0, count: 105) + Array(repeating: 37.49, count: 15)
  #expect(NightlyTemperature.calculate(samples: temperatures(below)) == 35)
}

@Test func temperatureGapsDoNotJoinPartialWindows() {
  let first = temperatures(Array(repeating: 35, count: 59))
  let second = temperatures(Array(repeating: 35, count: 61), offset: 3_600)
  #expect(NightlyTemperature.calculate(samples: first + second) == nil)
  let complete =
    temperatures(Array(repeating: 35, count: 60))
    + temperatures(Array(repeating: 34, count: 60), offset: 3_600)
  #expect(NightlyTemperature.calculate(samples: complete) == 34)
}

@Test func duplicateTemperaturesDoNotManufactureCoverageAndConflictsBreakContinuity() {
  let short = temperatures(Array(repeating: 35, count: 60))
  #expect(NightlyTemperature.calculate(samples: short + short) == nil)
  let full = temperatures(Array(repeating: 35, count: 120))
  #expect(NightlyTemperature.calculate(samples: full + full) == 35)
  let conflict = temperatures([36], offset: 59 * 30)
  #expect(NightlyTemperature.calculate(samples: full + conflict) == nil)
}

@Test func invalidTemperatureCannotBeReplacedWithAnotherMeasurementKind() {
  var values = Array(repeating: 35.0, count: 120)
  values[59] = .nan
  var samples = temperatures(values)
  let date = samples[59].end
  samples.append(
    OuraProtocol.Measurement(
      id: "heart", kind: .heartRate, start: date, end: date, value: 35))
  #expect(NightlyTemperature.calculate(samples: samples) == nil)
}
