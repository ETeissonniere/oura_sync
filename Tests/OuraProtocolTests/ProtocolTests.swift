import Foundation
import Testing

@testable import OuraProtocol

@Test func concatenatedPacketsAreAllDecoded() throws {
  let bytes = Data([0x0d, 2, 82, 0, 0x2f, 2, 0x2e, 0])
  #expect(
    try Packet.decode(bytes) == [
      Packet(tag: 0x0d, payload: [82, 0]), Packet(tag: 0x2f, payload: [0x2e, 0]),
    ])
}

@Test(arguments: [[UInt8](arrayLiteral: 0x0d), [0x0d, 2, 82], [0x0d, 1, 82, 0x2f]])
func partialNotificationIsNeverAccepted(bytes: [UInt8]) {
  #expect(throws: ProtocolError.truncatedPacket) { try Packet.decode(Data(bytes)) }
}

@Test func authenticatesUsingPublishedHorizonVector() throws {
  // Public research fixture, never a production key.
  let key = Data([
    0x44, 0x31, 0x96, 0x7d, 0x8b, 0xac, 0xc2, 0x65, 0x97, 0x43, 0x14, 0x2b, 0x68, 0x39, 0x1d, 0x9a,
  ])
  let nonce = Data([
    0x0e, 0x2d, 0x6a, 0x0a, 0x08, 0xc9, 0x9b, 0x43, 0x65, 0xf4, 0x58, 0xe6, 0xe9, 0x73, 0x82,
  ])
  let expected = Data([
    0xa3, 0x8a, 0x87, 0x72, 0xd3, 0xac, 0xb6, 0xdb, 0x5c, 0x2b, 0x51, 0x6d, 0xd5, 0x69, 0x87, 0xc8,
  ])
  #expect(try Authentication.challengeResponse(key: key, nonce: nonce) == expected)
}

@Test func invalidNonceIsRejectedInsteadOfTruncated() {
  #expect(throws: ProtocolError.invalidNonceLength) {
    try Authentication.challengeResponse(
      key: Data(repeating: 0, count: 16), nonce: Data(repeating: 0, count: 16))
  }
}

@Test func interruptedHistoryCannotAdvanceCheckpoint() {
  #expect(throws: ProtocolError.missingSummary) {
    try HistoryBatch(packets: [Packet(tag: 0x46, payload: [100, 0, 0, 0, 42])], requestedCursor: 0)
  }
}

@Test func replayedHorizonTailDoesNotAdvanceCursor() throws {
  let packets = [
    Packet(tag: 0x46, payload: [100, 0, 0, 0, 42]), Packet(tag: 0x11, payload: [1, 0, 0, 0, 0, 0]),
  ]
  let batch = try HistoryBatch(packets: packets, requestedCursor: 101)
  #expect(batch.events.isEmpty)
  #expect(batch.nextCursor == 101)
}

@Test func completeBatchRetainsUnknownEventBody() throws {
  let packets = [
    Packet(tag: 0xee, payload: [100, 0, 0, 0, 42, 99]),
    Packet(tag: 0x11, payload: [1, 0, 12, 0, 0, 0]),
  ]
  let batch = try HistoryBatch(packets: packets, requestedCursor: 0)
  #expect(batch.events.first?.body == Data([42, 99]))
  #expect(batch.nextCursor == 101)
  #expect(batch.bytesRemaining == 12)
}

@Test func missingEventPreventsCheckpoint() {
  #expect(throws: ProtocolError.eventCountMismatch) {
    try HistoryBatch(packets: [Packet(tag: 0x11, payload: [1, 0, 0, 0, 0, 0])], requestedCursor: 0)
  }
}

@Test func legacyFetchMatchesHorizonWireFormat() throws {
  #expect(
    try Commands.history(cursor: 100).encoded()
      == Data([0x10, 9, 100, 0, 0, 0, 255, 255, 255, 255, 255]))
}
