import Foundation
import Testing

@testable import OuraProtocol

@Test func publishedLiveHeartRateFramePreservesFractionalBPM() throws {
  // Public open_oura/crates/oura-link/src/client.rs fixture, not a user capture.
  let notification = try RingNotification(
    data: Data([0x2f, 0x08, 0x28, 0x02, 0x00, 0x02, 0x00, 0x00, 0x59, 0x13]))
  let reading = try #require(notification.liveHeartRate.first)
  #expect(reading.ibiMilliseconds == 857)
  #expect(abs(reading.beatsPerMinute - 60_000.0 / 857) < 0.000001)
  #expect(notification.replies.isEmpty)
}

@Test(arguments: [
  [UInt8(0x28)],
  [0x28, 4, 0, 2, 0, 0, 0x59, 0x13],
  [0x28, 2, 1, 2, 0, 0, 0x59, 0x13],
  [0x28, 2, 0, 2, 0, 0, 0x59, 0x03],
  [0x28, 2, 0, 2, 0, 0, 0x59, 0x23],
  [0x28, 2, 0, 2, 0, 0, 0x2b, 0x11],
  [0x28, 2, 0, 2, 0, 0, 0xd1, 0x17],
])
func invalidLiveIndicationsCannotBecomeReadingsOrCommandReplies(payload: [UInt8]) throws {
  let frame = Packet(tag: 0x2f, payload: payload)
  let notification = try RingNotification(data: frame.encoded())
  #expect(notification.liveHeartRate.isEmpty)
  #expect(notification.replies.isEmpty)
}

@Test func liveIndicationsPreserveHistoryHintsAndTerminalReplies() throws {
  let packets = [
    Packet(tag: 0x2f, payload: [0x28, 2, 0, 99, 0, 0, 0x2c, 0x11]),
    Packet(tag: 0x11, payload: [0, 0, 0, 0, 0, 0]),
    Packet(tag: 0x1f),
    Packet(tag: 0x2f, payload: [0x28, 2, 0, 0, 0, 0, 0xd0, 0x17]),
  ]
  let data = try packets.reduce(into: Data()) { $0.append(try $1.encoded()) }
  let notification = try RingNotification(data: data)
  #expect(notification.liveHeartRate.map(\.beatsPerMinute) == [200, 30])
  #expect(notification.historyAvailable)
  #expect(notification.replies == [packets[1]])
  #expect(try HistoryBatch(packets: notification.replies, requestedCursor: 0).events.isEmpty)
  #expect(LiveHeartRateReading(packet: Packet(tag: 0x28, payload: packets[0].payload)) == nil)
}
