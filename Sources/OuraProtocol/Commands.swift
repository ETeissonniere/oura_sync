import Foundation

public enum Commands {
  public static let service = "98ED0001-A541-11E4-B6A0-0002A5D5C51B"
  public static let writeCharacteristic = "98ED0002-A541-11E4-B6A0-0002A5D5C51B"
  public static let notifyCharacteristic = "98ED0003-A541-11E4-B6A0-0002A5D5C51B"
  public static let nonce = Packet(tag: 0x2f, payload: [0x2b])
  public static let battery = Packet(tag: 0x0c)
  public static let firmware = Packet(tag: 0x08, payload: [0, 0, 0])
  public static let registerStream = Packet(tag: 0x16, payload: [2])
  public static let flushHistory = Packet(tag: 0x28, payload: [0])

  public static func installKey(_ key: Data) throws -> Packet {
    guard key.count == 16 else { throw ProtocolError.invalidKeyLength }
    return Packet(tag: 0x24, payload: Array(key))
  }

  public static func authenticate(key: Data, nonce: Data) throws -> Packet {
    Packet(
      tag: 0x2f,
      payload: [0x2d] + Array(try Authentication.challengeResponse(key: key, nonce: nonce)))
  }

  public static func capabilities(page: UInt8) -> Packet {
    Packet(tag: 0x2f, payload: [1, page])
  }

  public static func history(cursor: UInt32) -> Packet {
    let bytes = (0..<4).map { UInt8(truncatingIfNeeded: cursor >> ($0 * 8)) }
    return Packet(tag: 0x10, payload: bytes + [255, 255, 255, 255, 255])
  }

  public static func synchronizeTime(unixSeconds: UInt64, token: UInt8) -> Packet {
    let counter = unixSeconds / 256
    return Packet(
      tag: 0x12,
      payload: [
        token,
        UInt8(truncatingIfNeeded: counter), UInt8(truncatingIfNeeded: counter >> 8),
        UInt8(truncatingIfNeeded: counter >> 16), 0, 0, 0, 0, 0xf6,
      ])
  }
}
