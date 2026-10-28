import Testing

@testable import OuraProtocol

@Test func oxygenBaselinesRecoverTheirTimesFromPulseSequence() {
  var buffer = OxygenOpticalBuffer()
  buffer.addPulses([5, 125, 125, 125, 125, 125, 125, 1, 1, 1, 1, 1, 1], endingAt: 6000)
  buffer.addBaselines([0x42, 100, 0, 0, 1, 1], endingAt: 3000)
  #expect(buffer.drain().isEmpty)
  #expect(
    buffer.drain(flush: true) == [
      .init(channel: 0, time: 1000, value: 100),
      .init(channel: 0, time: 2000, value: 101),
      .init(channel: 0, time: 3000, value: 102),
    ])
}

@Test func oxygenBaselineWithoutPulseContextWaitsInsteadOfInventingTime() {
  var buffer = OxygenOpticalBuffer()
  buffer.addBaselines([0x40, 100, 0, 0], endingAt: 1000)
  #expect(buffer.drain(flush: true).isEmpty)
  buffer.addPulses([5, 125, 125, 125, 125, 125, 125, 1, 1, 1, 1, 1, 1], endingAt: 6000)
  #expect(buffer.drain(flush: true) == [.init(channel: 0, time: 1000, value: 100)])
}

@Test func oxygenBatchResetRetainsBaselineButSessionEndClearsIt() {
  var buffer = OxygenOpticalBuffer()
  buffer.addBaselines([0x4f, 100, 0, 0], endingAt: 1000)
  buffer.reset(ended: false)
  #expect(
    buffer.addBaselines([0, 1], endingAt: 2000) == .decoded([.init(value: 101, sequence: 0)]))
  buffer.reset(ended: true)
  #expect(buffer.addBaselines([1, 1], endingAt: 3000) == .sequenceGap)
}
