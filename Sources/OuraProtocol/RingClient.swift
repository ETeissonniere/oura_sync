import Foundation

public struct Reply: Sendable {
  public let tag: UInt8
  public let extended: UInt8?
  public init(_ tag: UInt8, extended: UInt8? = nil) {
    self.tag = tag
    self.extended = extended
  }
  public func matches(_ packet: Packet) -> Bool {
    packet.tag == tag && (extended == nil || packet.payload.first == extended)
  }
}

public protocol RingConnection: Sendable {
  func exchange(_ packet: Packet, reply: Reply) async throws -> [Packet]
}

public struct RingClient: Sendable {
  public struct AuthenticationFailure: LocalizedError, Sendable {
    public let status: UInt8
    public var errorDescription: String? {
      status == 2
        ? "The ring is factory reset and needs a new key."
        : "The ring did not accept the saved key. Confirm that this ring was factory reset before setting it up again."
    }
  }
  public struct Failure: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
  }
  private let connection: any RingConnection
  public init(connection: any RingConnection) { self.connection = connection }

  public func installKey(_ key: Data) async throws {
    let result = try await single(Commands.installKey(key), reply: Reply(0x25))
    guard result.payload == [0] else {
      throw Failure(
        "The ring rejected key installation. It may not be factory reset. Your saved key has been kept for recovery."
      )
    }
    try await authenticate(key: key)
  }

  public func authenticate(key: Data) async throws {
    let nonce = try await single(Commands.nonce, reply: Reply(0x2f, extended: 0x2c))
    guard nonce.payload.count == 16 else { throw ProtocolError.invalidNonceLength }
    let result = try await single(
      Commands.authenticate(key: key, nonce: Data(nonce.payload.dropFirst())),
      reply: Reply(0x2f, extended: 0x2e))
    guard result.payload.count == 2 else {
      throw Failure("The ring returned an incomplete authentication result.")
    }
    guard result.payload[1] == 0 else { throw AuthenticationFailure(status: result.payload[1]) }
  }

  public func battery() async throws -> Int {
    let response = try await single(Commands.battery, reply: Reply(0x0d))
    guard let percent = response.payload.first, percent <= 100 else {
      throw Failure("The ring returned an invalid battery reading.")
    }
    return Int(percent)
  }

  public func prepareSync(now: Date = .now) async throws {
    // Gen 3 uses the legacy history path. The extra stream registration and
    // parameter sweep in open_oura's current client are specific to Ring 5.
    _ = try await single(Commands.capabilities(page: 0), reply: Reply(0x2f, extended: 2))
    let seconds = UInt64(max(0, now.timeIntervalSince1970))
    _ = try await single(
      Commands.synchronizeTime(unixSeconds: seconds, token: UInt8(truncatingIfNeeded: seconds)),
      reply: Reply(0x13))
    _ = try await single(Packet(tag: 0x1c, payload: [0x3f]), reply: Reply(0x1d))
  }

  public func enableDaytimeHeartRate() async throws {
    try await setRecordingMode(feature: 2, mode: 1, name: "Daytime heart-rate")
  }

  public func enableOxygenSaturation() async throws {
    try await setRecordingMode(feature: 4, mode: 1, name: "Blood-oxygen")
  }

  public func enableLiveHeartRate() async throws {
    try await setRecordingMode(feature: 2, mode: 3, name: "Live heart-rate")
  }

  private func setRecordingMode(feature: UInt8, mode: UInt8, name: String) async throws {
    if try await recordingMode(feature: feature) == mode { return }
    let result = try await single(
      Packet(tag: 0x2f, payload: [0x22, feature, mode]), reply: Reply(0x2f, extended: 0x23))
    guard result.payload == [0x23, feature, 0] else {
      throw Failure("\(name) recording could not be enabled.")
    }
    guard try await recordingMode(feature: feature) == mode else {
      throw Failure(
        "\(name) recording is not yet confirmed. Setup will retry on the next sync.")
    }
  }

  private func recordingMode(feature: UInt8) async throws -> UInt8 {
    let status = try await single(
      Packet(tag: 0x2f, payload: [0x20, feature]), reply: Reply(0x2f, extended: 0x21))
    guard status.payload.count >= 6, status.payload[1] == feature else {
      throw Failure("The ring returned an incomplete recording status.")
    }
    return status.payload[2]
  }

  public func history(cursor: UInt32) async throws -> HistoryBatch {
    _ = try await single(Commands.flushHistory, reply: Reply(0x29))
    let packets = try await connection.exchange(
      Commands.history(cursor: cursor), reply: Reply(0x11))
    try checkAuthentication(packets)
    return try HistoryBatch(packets: packets, requestedCursor: cursor)
  }

  private func single(_ request: Packet, reply: Reply) async throws -> Packet {
    let packets = try await connection.exchange(request, reply: reply)
    try checkAuthentication(packets)
    guard let result = packets.first(where: reply.matches) else {
      throw Failure("The ring response was incomplete.")
    }
    return result
  }

  private func checkAuthentication(_ packets: [Packet]) throws {
    if packets.contains(where: { $0.tag == 0x2f && $0.payload.first == 0x2f }) {
      throw Failure("The ring requires authentication. Reconnect and try again.")
    }
  }
}
