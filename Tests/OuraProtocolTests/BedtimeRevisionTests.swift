import Foundation
import Testing

@testable import OuraProtocol

private let bedtimeNow = Date(timeIntervalSince1970: 1_790_000_000)
private func bedtimeBytes(_ value: UInt32) -> [UInt8] {
  (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
}
private func bedtimeRevision(end: UInt32, emitted: UInt32) throws -> RingEvent {
  try RingEvent(
    packet: Packet(
      tag: 0x76, payload: bedtimeBytes(emitted) + bedtimeBytes(10_000) + bedtimeBytes(end)))
}
private func bedtimeAnchor() throws -> RingEvent {
  try RingEvent(
    packet: Packet(tag: 0x42, payload: bedtimeBytes(20_000) + bedtimeBytes(1_790_000_000)))
}

@Test(arguments: [UInt32(18_000), UInt32(12_000)])
func laterBedtimeRevisionReplacesLongerOrShorterWindowRegardlessOfInputOrder(end: UInt32) throws {
  let old = try bedtimeRevision(end: 15_000, emitted: 16_000)
  let revised = try bedtimeRevision(end: end, emitted: 19_000)
  let anchor = try bedtimeAnchor()
  let session = UUID()
  let original = Measurements(events: [anchor, old], session: session, now: bedtimeNow)
  let updated = Measurements(
    events: [revised, anchor, old, revised], session: session, now: bedtimeNow)
  #expect(updated.samples.count == 1)
  #expect(updated.samples.first?.id == original.samples.first?.id)
  #expect(
    updated.samples.first?.end == bedtimeNow.addingTimeInterval(Double(Int64(end) - 20_000) / 10))
  #expect(NightlyVitals.calculate(measurements: updated.samples, session: session).count == 1)
}

@Test func conflictingLatestBedtimesRemainAmbiguousUntilANewerRevision() throws {
  let first = try bedtimeRevision(end: 15_000, emitted: 18_000)
  let conflict = try bedtimeRevision(end: 16_000, emitted: 18_000)
  let events = try [bedtimeAnchor(), first, conflict, first]
  #expect(Measurements(events: events, session: UUID(), now: bedtimeNow).samples.isEmpty)
  let later = try bedtimeRevision(end: 17_000, emitted: 19_000)
  #expect(
    Measurements(events: events + [later], session: UUID(), now: bedtimeNow).samples.count == 1)
}

@Test func malformedNewerBedtimeDoesNotReplaceValidRevision() throws {
  let events = try [
    bedtimeAnchor(), bedtimeRevision(end: 15_000, emitted: 16_000),
    bedtimeRevision(end: 10_000, emitted: 18_000),
    bedtimeRevision(end: 900_000, emitted: 19_000),
  ]
  let decoded = Measurements(events: events, session: UUID(), now: bedtimeNow)
  #expect(decoded.samples.count == 1)
  #expect(decoded.samples.first?.end == bedtimeNow.addingTimeInterval(-500))
}

@Test func sleepStagesAssociateOnlyWithTheCanonicalBedtimeRevision() throws {
  let events = try [
    bedtimeAnchor(), bedtimeRevision(end: 16_000, emitted: 17_000),
    bedtimeRevision(end: 19_000, emitted: 19_500),
    RingEvent(
      packet: Packet(
        tag: 0x5a, payload: bedtimeBytes(20_000) + [0] + Array(repeating: 0, count: 13))),
  ]
  let session = UUID()
  let period = try #require(
    SleepStages(events: events, session: session, now: bedtimeNow).periods.first)
  let bedtime = try #require(
    Measurements(events: events, session: session, now: bedtimeNow).samples.first)
  #expect(period.recordedBedtime == DateInterval(start: bedtime.start, end: bedtime.end))
}

@Test func bedtimeCorrectionUsesSameHealthIdentityAndHigherJournalVersion() async throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: folder) }
  let store = try EventStore(url: folder.appendingPathComponent("history.sqlite"))
  let session = UUID()
  let events = try [bedtimeAnchor(), bedtimeRevision(end: 15_000, emitted: 16_000)]
  let original = Measurements(events: events, session: session, now: bedtimeNow).samples
  let first = try await store.prepareHealthExports(original)
  try await store.completeHealthExports(first)
  let revision = try bedtimeRevision(end: 18_000, emitted: 19_000)
  let corrected = Measurements(events: events + [revision], session: session, now: bedtimeNow)
    .samples
  let next = try await store.prepareHealthExports(corrected)
  #expect(next.first?.measurement.id == first.first?.measurement.id)
  #expect(next.first?.version == 3)
  try await store.completeHealthExports(first)
  #expect(try await store.prepareHealthExports(corrected) == next)
}

@Test func bedtimeClockCorrectionKeepsIdentityAndUpdatesHealthDates() async throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: folder) }
  let store = try EventStore(url: folder.appendingPathComponent("history.sqlite"))
  let session = UUID()
  let events = try [bedtimeAnchor(), bedtimeRevision(end: 15_000, emitted: 16_000)]
  let original = Measurements(events: events, session: session, now: bedtimeNow).samples
  let first = try await store.prepareHealthExports(original)
  try await store.completeHealthExports(first)
  let correction = try RingEvent(
    packet: Packet(tag: 0x42, payload: bedtimeBytes(14_000) + bedtimeBytes(1_789_999_500)))
  let corrected = Measurements(events: events + [correction], session: session, now: bedtimeNow)
    .samples
  let next = try await store.prepareHealthExports(corrected)
  #expect(next.count == 1)
  #expect(next.first?.measurement.id == first.first?.measurement.id)
  #expect(next.first?.version == 3)
  #expect(corrected.first?.start == original.first?.start.addingTimeInterval(100))
  #expect(corrected.first?.end == original.first?.end.addingTimeInterval(100))
}
