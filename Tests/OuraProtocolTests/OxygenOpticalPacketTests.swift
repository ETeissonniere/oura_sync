import Testing

@testable import OuraProtocol

@Test func oxygenBaselineSequenceWrapAndSignedDeltas() {
  let expected: [OxygenOpticalPacket.Baseline] = [
    .init(value: 100, sequence: 13), .init(value: 101, sequence: 14),
    .init(value: 99, sequence: 15),
  ]
  #expect(
    OxygenOpticalPacket.baselines([0x4f, 100, 0, 0, 1, 254], previous: nil) == .decoded(expected))
  #expect(
    OxygenOpticalPacket.baselines([0, 2], previous: expected.last)
      == .decoded([.init(value: 101, sequence: 0)]))
  #expect(OxygenOpticalPacket.baselines([2, 2], previous: expected.last) == .sequenceGap)
  #expect(OxygenOpticalPacket.baselines([0, 2], previous: nil) == .sequenceGap)
}

@Test func oxygenBaselineResetSkipAndUnsignedArithmetic() {
  #expect(OxygenOpticalPacket.baselines([0x44, 0, 0, 8], previous: nil) == .skipped)
  #expect(
    OxygenOpticalPacket.baselines([0x44, 255, 255, 7], previous: nil)
      == .decoded([.init(value: 0x7ffff, sequence: 4)]))
  #expect(
    OxygenOpticalPacket.baselines([0, 255], previous: .init(value: 0, sequence: 15))
      == .decoded([.init(value: .max, sequence: 0)]))
}

@Test(arguments: [
  [UInt8](), [0x40], [0x40, 1], [0x40, 1, 2], [0], Array(repeating: UInt8(0), count: 15),
])
func malformedOxygenBaselinesAreRejected(bytes: [UInt8]) {
  #expect(OxygenOpticalPacket.baselines(bytes, previous: nil) == .malformed)
}

@Test func oxygenPulseTimingUsesNearestValidIntervalWithEarlierTie() throws {
  let pulses = try #require(
    OxygenOpticalPacket.pulses([0, 100, 250, 125, 100, 100, 100, 1, 0, 1, 1, 1, 1], endingAt: 5000))
  #expect(pulses.map(\.time) == [800, 1600, 2600, 3400, 4200, 5000])
  #expect(pulses.map(\.sequence) == [11, 12, 13, 14, 15, 0])
  #expect(pulses.map(\.valid) == [true, false, true, true, true, true])
}

@Test func invalidOxygenPulsesRetainInvalidityAndUseFallbackSpacing() throws {
  let bytes: [UInt8] = [0x10, 250, 250, 250, 250, 250, 250, 0, 0, 0, 0, 0, 0]
  let pulses = try #require(OxygenOpticalPacket.pulses(bytes, endingAt: 1000))
  #expect(pulses.map(\.time) == [-2750, -2000, -1250, -500, 250, 1000])
  #expect(pulses.allSatisfy { !$0.valid && $0.amplitude == 0 })
  #expect(OxygenOpticalPacket.pulses(bytes, endingAt: .min) == nil)
  #expect(OxygenOpticalPacket.pulses(Array(bytes.dropLast()), endingAt: 1000) == nil)
}
