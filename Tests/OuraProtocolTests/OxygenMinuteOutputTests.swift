import Testing

@testable import OuraProtocol

@Test func oxygenMinuteEmitsBeforeAddingBoundarySampleAndOmitsTail() {
  let samples: [OxygenQualityQueue.Sample] = [
    .init(time: 0, value: 94), .init(time: 30000, value: 95),
    .init(time: 60000, value: 80), .init(time: 61000, value: 80),
  ]
  #expect(
    OxygenMinuteOutput.aggregate(samples: samples, accepted: [true, true, true, true])
      == [.init(time: 30000, value: 95, quality: true)])
}

@Test(arguments: [(0, false), (1, false), (2, true)])
func oxygenMinuteQualityUsesReceivedSamples(validCount: Int, expectedQuality: Bool) {
  var samples = (0..<20).map { OxygenQualityQueue.Sample(time: Int64($0) * 1000, value: 95) }
  samples.append(.init(time: 60000, value: 95))
  let output = OxygenMinuteOutput.aggregate(
    samples: samples,
    accepted: samples.indices.map { $0 < validCount })
  if validCount == 0 {
    #expect(output.isEmpty)
  } else {
    #expect(output == [.init(time: 19000, value: 95, quality: expectedQuality)])
  }
}

@Test func sparseOxygenMinuteDoesNotClaimTemporalCoverage() {
  let samples: [OxygenQualityQueue.Sample] = [
    .init(time: 1000, value: 95), .init(time: 91000, value: 96),
  ]
  #expect(
    OxygenMinuteOutput.aggregate(samples: samples, accepted: [true, true])
      == [.init(time: 1000, value: 95, quality: true)])
}
