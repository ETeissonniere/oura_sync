import Foundation

public struct RingEvent: Codable, Hashable, Sendable {
  public let tag: UInt8
  public let timestamp: UInt32
  public let body: Data

  public init(packet: Packet) throws {
    guard packet.tag >= 0x41, packet.payload.count >= 4 else {
      throw ProtocolError.malformedEvent
    }
    tag = packet.tag
    timestamp = packet.payload.uint32(at: 0)
    body = Data(packet.payload.dropFirst(4))
  }
}

public struct HistoryBatch: Sendable {
  public let requestedCursor: UInt32
  public let events: [RingEvent]
  public let bytesRemaining: UInt32
  public let nextCursor: UInt32

  public init(packets: [Packet], requestedCursor: UInt32) throws {
    self.requestedCursor = requestedCursor
    let summaries = packets.filter { $0.tag == 0x11 }
    guard let summary = summaries.first else { throw ProtocolError.missingSummary }
    guard summaries.count == 1, summary.payload.count >= 6,
      packets.last == summary
    else { throw ProtocolError.malformedSummary }
    let received = try packets.filter { $0.tag >= 0x41 }.map(RingEvent.init)
    guard received.count == Int(summary.payload[0]) else {
      throw ProtocolError.eventCountMismatch
    }
    events = received.filter { $0.timestamp >= requestedCursor }
    bytesRemaining = summary.payload.uint32(at: 2)
    if let latest = events.map(\.timestamp).max() {
      guard latest < UInt32.max else { throw ProtocolError.cursorOverflow }
      nextCursor = latest + 1
    } else {
      nextCursor = requestedCursor
    }
  }
}
