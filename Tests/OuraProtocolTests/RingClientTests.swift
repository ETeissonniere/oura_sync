import Foundation
import Testing

@testable import OuraProtocol

private actor ScriptedRing: RingConnection {
  var responses: [[Packet]]
  var sent: [Packet] = []
  init(_ responses: [[Packet]]) { self.responses = responses }
  func exchange(_ packet: Packet, reply: Reply) async throws -> [Packet] {
    sent.append(packet)
    guard !responses.isEmpty else { throw RingClient.Failure("Unexpected request") }
    return responses.removeFirst()
  }
}

@Test func installationMustAuthenticateBeforeSucceeding() async throws {
  let ring = ScriptedRing([
    [Packet(tag: 0x25, payload: [0])],
    [Packet(tag: 0x2f, payload: [0x2c] + Array(repeating: 7, count: 15))],
    [Packet(tag: 0x2f, payload: [0x2e, 1])],
  ])
  await #expect(throws: RingClient.AuthenticationFailure.self) {
    try await RingClient(connection: ring).installKey(Data(repeating: 2, count: 16))
  }
  let sent = await ring.sent
  #expect(sent.map(\.tag) == [0x24, 0x2f, 0x2f])
  #expect(sent.last?.payload.first == 0x2d)
}

@Test func rejectedKeyInstallationStopsImmediately() async throws {
  let ring = ScriptedRing([[Packet(tag: 0x25, payload: [1])]])
  await #expect(throws: RingClient.Failure.self) {
    try await RingClient(connection: ring).installKey(Data(repeating: 2, count: 16))
  }
  #expect(await ring.sent.count == 1)
}

@Test func historyFlushesThenFetchesWithoutStallingAcknowledgment() async throws {
  let ring = ScriptedRing([
    [Packet(tag: 0x29, payload: [0])],
    [
      Packet(tag: 0x46, payload: [100, 0, 0, 0, 20]),
      Packet(tag: 0x11, payload: [1, 0, 0, 0, 0, 0]),
    ],
  ])
  let batch = try await RingClient(connection: ring).history(cursor: 100)
  #expect(batch.nextCursor == 101)
  #expect(await ring.sent == [Commands.flushHistory, Commands.history(cursor: 100)])
}

@Test func authenticationRequiredIsNotAnEmptyHistoryBatch() async throws {
  let ring = ScriptedRing([
    [Packet(tag: 0x29, payload: [0])], [Packet(tag: 0x2f, payload: [0x2f, 1])],
  ])
  await #expect(throws: RingClient.Failure.self) {
    try await RingClient(connection: ring).history(cursor: 100)
  }
}

private func enableRecording(_ feature: UInt8, on ring: ScriptedRing) async throws {
  let client = RingClient(connection: ring)
  if feature == 2 {
    try await client.enableDaytimeHeartRate()
  } else {
    try await client.enableOxygenSaturation()
  }
}

@Test func liveModeRequiresReadbackAndAutomaticModeCanBeRestored() async throws {
  let ring = ScriptedRing([
    [Packet(tag: 0x2f, payload: [0x21, 2, 1, 0, 0, 0])],
    [Packet(tag: 0x2f, payload: [0x23, 2, 0])],
    [Packet(tag: 0x2f, payload: [0x21, 2, 3, 0, 0, 0])],
    [Packet(tag: 0x2f, payload: [0x21, 2, 3, 0, 0, 0])],
    [Packet(tag: 0x2f, payload: [0x23, 2, 0])],
    [Packet(tag: 0x2f, payload: [0x21, 2, 1, 0, 0, 0])],
  ])
  let client = RingClient(connection: ring)
  try await client.enableLiveHeartRate()
  try await client.enableDaytimeHeartRate()
  #expect(
    await ring.sent.map(\.payload) == [
      [0x20, 2], [0x22, 2, 3], [0x20, 2], [0x20, 2], [0x22, 2, 1], [0x20, 2],
    ])
}

@Test func liveModeAcknowledgmentWithoutMatchingReadbackFails() async throws {
  let ring = ScriptedRing([
    [Packet(tag: 0x2f, payload: [0x21, 2, 1, 0, 0, 0])],
    [Packet(tag: 0x2f, payload: [0x23, 2, 0])],
    [Packet(tag: 0x2f, payload: [0x21, 2, 1, 0, 0, 0])],
  ])
  await #expect(throws: RingClient.Failure.self) {
    try await RingClient(connection: ring).enableLiveHeartRate()
  }
}

@Test func alreadyLiveModeDoesNotRewriteFeature() async throws {
  let ring = ScriptedRing([[Packet(tag: 0x2f, payload: [0x21, 2, 3, 0, 0, 0])]])
  try await RingClient(connection: ring).enableLiveHeartRate()
  #expect(await ring.sent.map(\.payload) == [[0x20, 2]])
}

@Test(arguments: [UInt8(2), UInt8(4)])
func automaticRecordingReadsBeforeWritingAndVerifiesMode(feature: UInt8) async throws {
  let ring = ScriptedRing([
    [Packet(tag: 0x2f, payload: [0x21, feature, 0, 0, 0, 0])],
    [Packet(tag: 0x2f, payload: [0x23, feature, 0])],
    [Packet(tag: 0x2f, payload: [0x21, feature, 1, 0, 0, 0])],
  ])
  try await enableRecording(feature, on: ring)
  #expect(
    await ring.sent.map(\.payload) == [[0x20, feature], [0x22, feature, 1], [0x20, feature]])
}

@Test func alreadyEnabledOxygenRecordingDoesNotRewriteMode() async throws {
  let ring = ScriptedRing([[Packet(tag: 0x2f, payload: [0x21, 4, 1, 0, 0, 0])]])
  try await RingClient(connection: ring).enableOxygenSaturation()
  #expect(await ring.sent.map(\.payload) == [[0x20, 4]])
}

@Test(arguments: [[UInt8(0x21), 4, 0, 0, 0, 0], [0x21, 2, 1, 0, 0, 0], [0x21, 4, 1]])
func successfulAcknowledgmentCannotReplaceRecordingReadback(readback: [UInt8]) async throws {
  let ring = ScriptedRing([
    [Packet(tag: 0x2f, payload: [0x21, 4, 0, 0, 0, 0])],
    [Packet(tag: 0x2f, payload: [0x23, 4, 0])],
    [Packet(tag: 0x2f, payload: readback)],
  ])
  await #expect(throws: RingClient.Failure.self) {
    try await RingClient(connection: ring).enableOxygenSaturation()
  }
}

@Test(arguments: [[UInt8(0x23), 4, 1], [0x23, 2, 0], [0x2f, 1]])
func rejectedRecordingWriteNeverReportsEnabled(ack: [UInt8]) async throws {
  let ring = ScriptedRing([
    [Packet(tag: 0x2f, payload: [0x21, 4, 0, 0, 0, 0])],
    [Packet(tag: 0x2f, payload: ack)],
  ])
  await #expect(throws: RingClient.Failure.self) {
    try await RingClient(connection: ring).enableOxygenSaturation()
  }
  #expect(await ring.sent.count == 2)
}
