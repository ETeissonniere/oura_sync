import Foundation
import Testing

@testable import OuraProtocol

private func journalSleep(epochCount: Int = 3, stage: SleepStage = .light) -> SleepStagePeriod {
  let start = Date(timeIntervalSince1970: 1_790_000_000)
  let epochs = (0..<epochCount).map { index in
    SleepStageEpoch(
      id: "night.\(index)", stage: stage,
      start: start.addingTimeInterval(Double(index) * 30),
      end: start.addingTimeInterval(Double(index + 1) * 30))
  }
  return SleepStagePeriod(
    id: "night", session: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
    start: start, end: epochs.last!.end, epochs: epochs,
    recordedBedtime: DateInterval(start: start, end: epochs.last!.end),
    timing: .anchoredToSleepSummary)
}

@Test func interruptedSleepReplacementRetainsVersionAcrossRestart() async throws {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(
    UUID().uuidString + ".sqlite")
  let store = try EventStore(url: url)
  let first = try #require(await store.prepareSleepHealthExport(journalSleep()))
  let reopened = try EventStore(url: url)
  let retry = try #require(await reopened.prepareSleepHealthExport(journalSleep()))
  #expect(retry.version == first.version)
  try await reopened.completeSleepHealthExport(retry)
  #expect(try await reopened.prepareSleepHealthExport(journalSleep()) == nil)
}

@Test func shorterAndChangedSleepRevisionsRequireWholeNightReplacement() async throws {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(
    UUID().uuidString + ".sqlite")
  let store = try EventStore(url: url)
  let first = try #require(await store.prepareSleepHealthExport(journalSleep()))
  try await store.completeSleepHealthExport(first)
  let shorter = try #require(await store.prepareSleepHealthExport(journalSleep(epochCount: 2)))
  #expect(shorter.version == first.version + 1)
  let changed = try #require(
    await store.prepareSleepHealthExport(journalSleep(epochCount: 2, stage: .deep)))
  #expect(changed.version == shorter.version + 1)
  try await store.completeSleepHealthExport(shorter)
  let stillPending = try #require(
    await store.prepareSleepHealthExport(journalSleep(epochCount: 2, stage: .deep)))
  #expect(stillPending.version == changed.version)
  try await store.completeSleepHealthExport(changed)
  #expect(
    try await store.prepareSleepHealthExport(journalSleep(epochCount: 2, stage: .deep)) == nil)
}

@Test func newlyDiscoveredSleepAliasesRequireCleanupEvenWithUnchangedStages() async throws {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(
    UUID().uuidString + ".sqlite")
  let store = try EventStore(url: url)
  var period = journalSleep()
  let original = try #require(await store.prepareSleepHealthExport(period))
  try await store.completeSleepHealthExport(original)
  period.supersededIDs = ["older-night"]
  let cleanup = try #require(await store.prepareSleepHealthExport(period))
  #expect(cleanup.version == original.version + 1)
  let retry = try #require(await store.prepareSleepHealthExport(period))
  #expect(retry.version == cleanup.version)
  try await store.completeSleepHealthExport(retry)
  #expect(try await store.prepareSleepHealthExport(period) == nil)
}
