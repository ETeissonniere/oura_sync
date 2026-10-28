import Testing

@testable import OuraProtocol

@Test(arguments: [
  [UInt8(98), 98, 98, 98],
  [98, 97, 96, 97, 98],
  [98, 95, 95, 95],
])
func oxygenDetectorRequiresARecoveredDip(values: [UInt8]) {
  let samples = values.enumerated().map {
    OxygenQualityQueue.Sample(time: Int64($0.offset) * 1000, value: $0.element)
  }
  #expect(OxygenDipDetector.detect(samples).isEmpty)
}

@Test func oxygenDetectorUsesLastMinimumAndTrimsPlateaus() {
  let values: [UInt8] = [99, 98, 98, 95, 95, 98, 98, 99]
  let samples = values.enumerated().map {
    OxygenQualityQueue.Sample(time: Int64($0.offset) * 1000, value: $0.element)
  }
  #expect(OxygenDipDetector.detect(samples) == [.init(start: 2, end: 5, bottom: 4, depth: 3)])
}

@Test(arguments: [(Int64(180000), 1), (Int64(180001), 0)])
func oxygenDetectorLimitsCandidateDuration(duration: Int64, count: Int) {
  let samples: [OxygenQualityQueue.Sample] = [
    .init(time: 0, value: 99), .init(time: 1000, value: 98),
    .init(time: 91000, value: 95), .init(time: 1000 + duration, value: 98),
    .init(time: 200000, value: 99),
  ]
  #expect(OxygenDipDetector.detect(samples).count == count)
}
