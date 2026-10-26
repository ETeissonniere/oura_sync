public struct LiveHeartRateReading: Sendable, Equatable {
  public let ibiMilliseconds: Int
  public var beatsPerMinute: Double { 60_000 / Double(ibiMilliseconds) }

  public init?(packet: Packet) {
    let bytes = packet.payload
    guard packet.tag == 0x2f, bytes.count >= 8,
      bytes[0] == 0x28, bytes[1] == 2, bytes[2] == 0,
      bytes[7] >> 4 == 1
    else { return nil }
    let ibi = Int(bytes[6]) | (Int(bytes[7] & 15) << 8)
    guard (300...2_000).contains(ibi) else { return nil }
    ibiMilliseconds = ibi
  }
}
