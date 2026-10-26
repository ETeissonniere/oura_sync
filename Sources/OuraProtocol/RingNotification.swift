import Foundation

public struct RingNotification: Sendable {
  public let historyAvailable: Bool
  public let replies: [Packet]
  public let liveHeartRate: [LiveHeartRateReading]

  public init(data: Data) throws {
    let packets = try Packet.decode(data)
    historyAvailable = packets.contains { $0.tag == 0x1f }
    liveHeartRate = packets.compactMap(LiveHeartRateReading.init(packet:))
    // Unsolicited signals can accompany any reply, including its terminal frame.
    replies = packets.filter {
      $0.tag != 0x1f && !($0.tag == 0x2f && $0.payload.first == 0x28)
    }
  }
}
