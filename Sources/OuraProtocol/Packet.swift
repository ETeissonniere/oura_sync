import Foundation

public enum ProtocolError: Error, Equatable, Sendable {
  case truncatedPacket
  case payloadTooLarge
  case invalidKeyLength
  case invalidNonceLength
  case encryptionFailed(Int32)
  case malformedEvent
  case missingSummary
  case malformedSummary
  case eventCountMismatch
  case cursorOverflow
}

public struct Packet: Equatable, Sendable {
  public let tag: UInt8
  public let payload: [UInt8]

  public init(tag: UInt8, payload: [UInt8] = []) {
    self.tag = tag
    self.payload = payload
  }

  public func encoded() throws -> Data {
    guard payload.count <= 255 else { throw ProtocolError.payloadTooLarge }
    return Data([tag, UInt8(payload.count)] + payload)
  }

  // Reject the whole notification if a trailing frame is incomplete. Advancing
  // a history cursor past a partially decoded notification would lose data.
  public static func decode(_ data: Data) throws -> [Packet] {
    let bytes = Array(data)
    var offset = 0
    var result: [Packet] = []
    while offset < bytes.count {
      guard bytes.count - offset >= 2 else { throw ProtocolError.truncatedPacket }
      let end = offset + 2 + Int(bytes[offset + 1])
      guard end <= bytes.count else { throw ProtocolError.truncatedPacket }
      result.append(Packet(tag: bytes[offset], payload: Array(bytes[(offset + 2)..<end])))
      offset = end
    }
    return result
  }
}

extension Array where Element == UInt8 {
  func uint32(at index: Int) -> UInt32 {
    (0..<4).reduce(0) { $0 | UInt32(self[index + $1]) << ($1 * 8) }
  }
}
