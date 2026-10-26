import Foundation
import Testing

@testable import OuraProtocol

@Test(arguments: [true, false])
func historySignalBesideSummaryPreservesCompleteBatch(signalFirst: Bool) throws {
  let event = Packet(tag: 0x46, payload: [100, 0, 0, 0, 42])
  let summary = Packet(tag: 0x11, payload: [1, 0, 0, 0, 0, 0])
  let signal = Packet(tag: 0x1f)
  let packets = signalFirst ? [signal, event, summary] : [event, summary, signal]
  let bytes = try packets.reduce(into: Data()) { $0.append(try $1.encoded()) }
  let notification = try RingNotification(data: bytes)
  let batch = try HistoryBatch(packets: notification.replies, requestedCursor: 0)
  #expect(notification.historyAvailable)
  #expect(batch.events.count == 1)
  #expect(batch.nextCursor == 101)
}

@Test func historySignalDoesNotBecomeACommandReply() throws {
  let notification = try RingNotification(data: Data([0x1f, 0, 0x1f, 0]))
  #expect(notification.historyAvailable)
  #expect(notification.replies.isEmpty)
}

@Test func ordinaryReplyIsPreservedAndMalformedNotificationIsRejected() throws {
  let notification = try RingNotification(data: Data([0x0d, 1, 82]))
  #expect(!notification.historyAvailable)
  #expect(notification.replies == [Packet(tag: 0x0d, payload: [82])])
  #expect(throws: ProtocolError.truncatedPacket) {
    try RingNotification(data: Data([0x1f, 0, 0x0d, 2, 82]))
  }
}
