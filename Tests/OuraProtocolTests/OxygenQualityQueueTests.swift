import Testing

@testable import OuraProtocol

@Test func oxygenQualityWaitsForItsLookaheadWindow() {
  var queue = OxygenQualityQueue()
  for index in 0..<80 {
    #expect(queue.add(.init(time: Int64(index) * 1000, value: 95)) == (index >= 38))
    #expect(queue.samples.first?.time == Int64(max(0, index - 38)) * 1000)
  }
  #expect(queue.samples.count == 39)
}

@Test(arguments: [
  (UInt8(69), UInt8(2), false), (70, 2, true), (100, 10, true), (101, 2, false), (95, 11, false),
  (95, 1, false),
])
func oxygenQualityUsesNativeRangeAndMotionThresholds(value: UInt8, motion: UInt8, expected: Bool) {
  var queue = OxygenQualityQueue()
  queue.add(.init(time: 40000, value: value))
  queue.addMotion(at: 40000, value: motion)
  #expect(queue.evaluate(0, optical: OxygenOpticalBuffer()).valid == expected)
}

@Test func lowMotionOxygenNeedsEnoughOpticalSignal() {
  for amplitude: UInt8 in [1, 2] {
    var optical = OxygenOpticalBuffer()
    optical.addPulses(
      [0x85, 125, 125, 125, 125, 125, 125] + Array(repeating: amplitude, count: 6), endingAt: 6000)
    optical.addBaselines([0xc4, 232, 3, 0, 0, 0, 0, 0], endingAt: 5000)
    #expect(optical.drain(flush: true).count == 5)
    var queue = OxygenQualityQueue()
    queue.add(.init(time: 6000, value: 95))
    let result = queue.evaluate(0, optical: optical)
    #expect(result.optical.pulses == 5)
    #expect(result.optical.baseline == 5000)
    #expect(result.valid == (amplitude == 2))
  }
}

@Test func overlappingMotionRecordsDoNotDoubleCountTheWindow() {
  var queue = OxygenQualityQueue()
  queue.add(.init(time: 40000, value: 95))
  queue.addMotion(at: 40000, value: 11)
  queue.addMotion(at: 40000, value: 0)
  let result = queue.evaluate(0, optical: OxygenOpticalBuffer())
  #expect(result.coverage == 6000)
  #expect(result.motion == 11)
  #expect(!result.valid)
}
