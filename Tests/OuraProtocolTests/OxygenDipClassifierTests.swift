import Testing

@testable import OuraProtocol

@Test(arguments: [false, true])
func oxygenDipWithoutOpticalContextIsRejected(includeInfrared: Bool) throws {
  let quality = [UInt8(99), 98, 95, 98, 99].enumerated().map {
    OxygenQualityQueue.Evaluation(
      sample: .init(time: 10000 + Int64($0.offset) * 1000, value: $0.element),
      optical: .init(amplitude: 10, baseline: 1000, pulses: 5), motion: 2, coverage: 6000,
      valid: true)
  }
  let optical: [OxygenOpticalBuffer.Reading] =
    includeInfrared
    ? [.init(channel: 1, time: 12000, value: 1000)] : []
  let batch = OxygenEventProcessor.Batch(quality: quality, optical: optical)
  let dip = try #require(OxygenDipDetector.detect(quality.map(\.sample)).first)
  #expect(OxygenDipClassifier.probability(of: dip, in: batch) == 0)
}
