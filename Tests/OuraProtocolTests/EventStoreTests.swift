import Foundation
import Testing

@testable import OuraProtocol

@Test func batchAndCheckpointSurviveReopening() async throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: folder) }
  let url = folder.appendingPathComponent("history.sqlite")
  let session = UUID()
  let store = try EventStore(url: url)
  let batch = try storedBatch()
  try await store.commit(batch, session: session, expectedCursor: 0)
  let reopened = try EventStore(url: url)
  #expect(try await reopened.cursor(session: session) == 101)
  #expect(try await reopened.events(session: session) == batch.events)
}

@Test func staleWriterCannotOverwriteCheckpointOrDuplicateEvents() async throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: folder) }
  let store = try EventStore(url: folder.appendingPathComponent("history.sqlite"))
  let session = UUID()
  try await store.commit(storedBatch(), session: session, expectedCursor: 0)
  await #expect(throws: EventStore.Failure.self) {
    try await store.commit(storedBatch(), session: session, expectedCursor: 0)
  }
  #expect(try await store.events(session: session).count == 1)
  #expect(try await store.cursor(session: session) == 101)
  let resetSession = UUID()
  #expect(try await store.cursor(session: resetSession) == 0)
  try await store.commit(storedBatch(), session: resetSession, expectedCursor: 0)
  #expect(try await store.events(session: resetSession).count == 1)
  #expect(try await store.events(session: session).count == 1)
}

private func storedBatch() throws -> HistoryBatch {
  try HistoryBatch(
    packets: [
      Packet(tag: 0x46, payload: [100, 0, 0, 0, 32]),
      Packet(tag: 0x11, payload: [1, 0, 0, 0, 0, 0]),
    ], requestedCursor: 0)
}

@Test func historyRequestedPastCheckpointCannotSkipUnfetchedRecords() async throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: folder) }
  let url = folder.appendingPathComponent("history.sqlite")
  let store = try EventStore(url: url)
  let session = UUID()
  try await store.commit(storedBatch(), session: session, expectedCursor: 0)
  let mismatched = try HistoryBatch(
    packets: [
      Packet(tag: 0x46, payload: [200, 0, 0, 0, 32]),
      Packet(tag: 0x11, payload: [1, 0, 0, 0, 0, 0]),
    ], requestedCursor: 200)
  await #expect(throws: EventStore.Failure.self) {
    try await store.commit(mismatched, session: session, expectedCursor: 101)
  }
  let reopened = try EventStore(url: url)
  #expect(try await reopened.cursor(session: session) == 101)
  #expect(try await reopened.events(session: session).map(\.timestamp) == [100])
  let resumed = try HistoryBatch(
    packets: [
      Packet(tag: 0x46, payload: [150, 0, 0, 0, 32]),
      Packet(tag: 0x11, payload: [1, 0, 0, 0, 0, 0]),
    ], requestedCursor: 101)
  try await reopened.commit(resumed, session: session, expectedCursor: 101)
  #expect(try await reopened.cursor(session: session) == 151)
  #expect(try await reopened.events(session: session).map(\.timestamp) == [100, 150])
}

@Test func nightlySummariesDoNotBorrowReadingsFromAnotherPairingSession() async throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: folder) }
  let url = folder.appendingPathComponent("history.sqlite")
  let store = try EventStore(url: url)
  let bedtimeOnly = UUID()
  let completeNight = UUID()
  let now = Date(timeIntervalSince1970: 1_790_000_000)
  func bytes(_ value: UInt32) -> [UInt8] {
    (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
  }
  func batch(withVitals: Bool) throws -> HistoryBatch {
    var packets = [
      Packet(tag: 0x42, payload: bytes(12_000) + bytes(1_790_000_000)),
      Packet(tag: 0x76, payload: bytes(12_000) + bytes(6_000) + bytes(12_000)),
    ]
    if withVitals { packets.append(Packet(tag: 0x5d, payload: bytes(12_000) + [50, 40])) }
    packets.append(Packet(tag: 0x11, payload: [UInt8(packets.count), 0, 0, 0, 0, 0]))
    return try HistoryBatch(packets: packets, requestedCursor: 0)
  }
  try await store.commit(batch(withVitals: false), session: bedtimeOnly, expectedCursor: 0)
  try await store.commit(batch(withVitals: true), session: completeNight, expectedCursor: 0)
  let reopened = try EventStore(url: url)
  let history = try await reopened.recordedHistory(now: now)
  #expect(history.nightlyVitals.count == 2)
  let empty = try #require(history.nightlyVitals.first { $0.session == bedtimeOnly })
  let complete = try #require(history.nightlyVitals.first { $0.session == completeNight })
  #expect(empty.start == complete.start)
  #expect(empty.end == complete.end)
  #expect(empty.heartRate == nil)
  #expect(empty.hrv == nil)
  #expect(complete.heartRate?.average == 50)
  #expect(complete.hrv?.average == 40)
  #expect(complete.heartRate?.count == 1)
}

@Test func savedMeasurementsRemainVisibleAcrossResetsWithoutSharingClockAnchors() async throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: folder) }
  let store = try EventStore(url: folder.appendingPathComponent("history.sqlite"))
  let old = UUID()
  let current = UUID()
  let undated = UUID()
  let now = Date(timeIntervalSince1970: 1_790_000_000)
  func bytes(_ value: UInt32) -> [UInt8] {
    (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
  }
  func batch(unix: UInt32?) throws -> HistoryBatch {
    var packets: [Packet] = []
    if let unix { packets.append(Packet(tag: 0x42, payload: bytes(12_000) + bytes(unix))) }
    packets.append(Packet(tag: 0x5d, payload: bytes(12_000) + [50, 40]))
    packets.append(Packet(tag: 0x11, payload: [UInt8(packets.count), 0, 0, 0, 0, 0]))
    return try HistoryBatch(packets: packets, requestedCursor: 0)
  }
  try await store.commit(batch(unix: 1_789_913_600), session: old, expectedCursor: 0)
  try await store.commit(batch(unix: 1_790_000_000), session: current, expectedCursor: 0)
  try await store.commit(batch(unix: nil), session: undated, expectedCursor: 0)
  let history = try await store.recordedHistory(now: now)
  let heart = history.measurements.filter { $0.kind == .heartRate }
  #expect(heart.count == 2)
  #expect(heart.map(\.end) == [now.addingTimeInterval(-86_400), now])
  #expect(heart[0].id.hasPrefix(old.uuidString))
  #expect(heart[1].id.hasPrefix(current.uuidString))
  #expect(history.undatedEvents == 1)
  #expect(try await store.cursor(session: current) == 12_001)
  #expect(try await store.recordedHistory(now: now).measurements == history.measurements)
}
