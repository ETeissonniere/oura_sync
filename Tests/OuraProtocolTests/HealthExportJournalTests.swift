import Foundation
import Testing

@testable import OuraProtocol

private func journalMeasurement(seconds: TimeInterval = 0, value: Double = 60)
  -> OuraProtocol.Measurement
{
  let start = Date(timeIntervalSince1970: 1_790_000_000 + seconds)
  return Measurement(
    id: "stable-ring-sample", kind: .heartRate, start: start,
    end: start.addingTimeInterval(300), value: value)
}

@Test func pendingHealthExportSurvivesRestartWithSameIdentityAndVersion() async throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: folder) }
  let url = folder.appendingPathComponent("history.sqlite")
  let store = try EventStore(url: url)
  let first = try await store.prepareHealthExports([journalMeasurement()])
  #expect(first.count == 1)
  #expect(first.first?.version == 2)
  // A crash after HealthKit saves but before our acknowledgement is identical
  // to a crash before its save: replay the same HealthKit identity and version.
  let reopened = try EventStore(url: url)
  let retried = try await reopened.prepareHealthExports([journalMeasurement()])
  #expect(retried == first)
  try await reopened.completeHealthExports(retried)
  let again = try EventStore(url: url)
  #expect(try await again.prepareHealthExports([journalMeasurement()]).isEmpty)
}

@Test func correctedDatesIncrementHealthVersionAndOldCompletionCannotHideCorrection() async throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: folder) }
  let url = folder.appendingPathComponent("history.sqlite")
  let store = try EventStore(url: url)
  let original = try await store.prepareHealthExports([journalMeasurement()])
  try await store.completeHealthExports(original)
  let corrected = try await store.prepareHealthExports([journalMeasurement(seconds: 60)])
  #expect(corrected.first?.measurement.id == original.first?.measurement.id)
  #expect(corrected.first?.version == 3)
  try await store.completeHealthExports(original)
  #expect(try await store.prepareHealthExports([journalMeasurement(seconds: 60)]) == corrected)
  try await store.completeHealthExports(corrected)
  #expect(try await store.prepareHealthExports([journalMeasurement(seconds: 60)]).isEmpty)
}

@Test func changedPendingHealthValueGetsNewVersionEvenWhenRevertingToEarlierContent() async throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: folder) }
  let url = folder.appendingPathComponent("history.sqlite")
  let store = try EventStore(url: url)
  let original = try await store.prepareHealthExports([journalMeasurement()])
  let changed = try await store.prepareHealthExports([journalMeasurement(value: 70)])
  #expect(changed.first?.version == 3)
  let reverted = try await store.prepareHealthExports([journalMeasurement()])
  #expect(reverted.first?.version == 4)
  try await store.completeHealthExports(original + changed)
  #expect(try await store.prepareHealthExports([journalMeasurement()]) == reverted)
}

@Test func failedHealthPreparationRollsBackEarlierChangesInTheBatch() async throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: folder) }
  let store = try EventStore(url: folder.appendingPathComponent("history.sqlite"))
  let original = try await store.prepareHealthExports([journalMeasurement()])
  try await store.completeHealthExports(original)
  await #expect(throws: EncodingError.self) {
    try await store.prepareHealthExports([
      journalMeasurement(seconds: 60), journalMeasurement(value: .nan),
    ])
  }
  #expect(try await store.prepareHealthExports([journalMeasurement()]).isEmpty)
  let correction = try await store.prepareHealthExports([journalMeasurement(seconds: 60)])
  #expect(correction.first?.version == 3)
}
