import Testing

@testable import OuraProtocol

@Test func threeByteFeatureStopFlushesAndSkipsOldestSample() throws {
  var processor = OxygenEventProcessor()
  #expect(processor.process(tag: 0x6f, body: [0, 94, 95, 96], at: 10000).isEmpty)
  let batches = processor.process(tag: 0x6c, body: [4, 4, 1], at: 11000)
  let batch = try #require(batches.first)
  #expect(batches.count == 1)
  #expect(batch.quality.map(\.sample.value) == [95, 96])
  #expect(batch.quality.map(\.sample.time) == [4000, 5000])
  #expect(processor.process(tag: 0x6c, body: [4, 1, 1], at: 12000).isEmpty)
  let next = processor.process(tag: 0x6f, body: [0, 97, 255], at: 15000)
  #expect(next.first?.quality.map(\.sample.value) == [97])
}

@Test(arguments: [(Int64(2299), Int64(6000)), (Int64(2300), Int64(8300))])
func terminalOxygenPacketAlignsOnlyWithinNativeTolerance(offset: Int64, expected: Int64) throws {
  var processor = OxygenEventProcessor()
  #expect(processor.process(tag: 0x6f, body: [0, 94], at: 10000).isEmpty)
  let batches = processor.process(tag: 0x6f, body: [0, 95, 255], at: 11000 + offset)
  let batch = try #require(batches.first)
  #expect(batch.quality.map(\.sample.time) == [5000, expected])
}

@Test func fullOxygenBatchRetainsAllLookaheadSamplesAndContinues() throws {
  var processor = OxygenEventProcessor()
  for index in 0..<1798 {
    #expect(processor.process(tag: 0x6f, body: [0, 95], at: 5000 + Int64(index) * 1000).isEmpty)
  }
  let batches = processor.process(tag: 0x6f, body: [0, 95], at: 1_803_000)
  let batch = try #require(batches.first)
  #expect(batch.quality.count == 1799)
  #expect(batch.quality.map(\.sample.time) == (0..<1799).map { Int64($0) * 1000 })
  let tail = processor.process(tag: 0x6f, body: [0, 96, 255], at: 1_804_000)
  #expect(tail.first?.quality.map(\.sample.time) == [1_799_000])
}
