import HealthKit
import OuraProtocol
import XCTest

@testable import OuraSync

@MainActor
final class HealthExporterTests: XCTestCase {
  func testUncalibratedOxygenIsNeitherRequestedNorExportedEvenWithExistingPermission() async throws
  {
    XCTAssertNil(HealthExporter.types[.oxygenSaturation])
    XCTAssertFalse(HealthExporter.types.values.contains(HKQuantityType(.oxygenSaturation)))
    var samples: [HKSample] = []
    let exporter = HealthExporter(
      enabled: true, authorizationStatus: { _ in .sharingAuthorized },
      save: { samples.append(contentsOf: $0) })
    let oxygen = try measurement(id: "oxygen", kind: .oxygenSaturation, value: 97)
    await exporter.export([oxygen])
    let journal = try EventStore(url: temporaryJournalURL())
    await exporter.export([oxygen], journal: journal)
    XCTAssertTrue(samples.isEmpty)
  }

  func testLargeSnapshotIsSavedInBoundedBatches() async throws {
    var batches: [[HKSample]] = []
    let exporter = HealthExporter(
      enabled: true, authorizationStatus: { _ in .sharingAuthorized },
      save: { batches.append($0) })
    let measurements = try (0..<1_001).map { try measurement(id: "reading-\($0)") }

    await exporter.export(measurements)

    XCTAssertEqual(batches.map(\.count), [500, 500, 1])
    XCTAssertEqual(
      batches.flatMap { $0 }.compactMap(syncIdentifier),
      measurements.map { "ourasync.\($0.id)" })
    XCTAssertFalse(exporter.busy)
  }

  @available(iOS 27, *)
  func testHealthSamplesPreserveUnitsDatesAndIdentityWithoutExportingUnsupportedMetrics()
    async throws
  {
    var samples: [HKSample] = []
    let exporter = HealthExporter(
      enabled: true, authorizationStatus: { _ in .sharingAuthorized },
      save: { samples.append(contentsOf: $0) })
    let input = try [
      measurement(id: "respiration", kind: .respiratoryRate, value: 15),
      measurement(id: "rmssd", kind: .hrvRMSSD, value: 48),
      measurement(id: "bed", kind: .inBed, value: 1),
      measurement(id: "skin", kind: .skinTemperature, value: 33.4),
      measurement(id: "activity", kind: .activityMET, value: 1.6),
    ]

    await exporter.export(input)

    XCTAssertEqual(samples.count, 3)
    let respiration = try XCTUnwrap(
      samples.first { syncIdentifier($0) == "ourasync.respiration" } as? HKQuantitySample)
    XCTAssertEqual(respiration.quantityType, HKQuantityType(.respiratoryRate))
    XCTAssertEqual(
      respiration.quantity.doubleValue(for: .count().unitDivided(by: .minute())), 15,
      accuracy: 0.000001)
    let rmssd = try XCTUnwrap(
      samples.first { syncIdentifier($0) == "ourasync.rmssd" } as? HKQuantitySample)
    XCTAssertEqual(rmssd.quantityType, HKQuantityType(.heartRateVariabilityRMSSD))
    XCTAssertEqual(rmssd.quantity.doubleValue(for: .secondUnit(with: .milli)), 48)
    let bed = try XCTUnwrap(
      samples.first { syncIdentifier($0) == "ourasync.bed" } as? HKCategorySample)
    XCTAssertEqual(bed.categoryType, HKCategoryType(.sleepAnalysis))
    XCTAssertEqual(bed.value, HKCategoryValueSleepAnalysis.inBed.rawValue)
    for sample in samples {
      XCTAssertEqual(sample.startDate, input[0].start)
      XCTAssertEqual(sample.endDate, input[0].end)
      XCTAssertEqual(sample.metadata?[HKMetadataKeySyncVersion] as? Int, 1)
    }
  }

  func testNewerSnapshotReplacesQueuedSnapshotWhileSaveIsSuspended() async throws {
    let gate = SaveGate()
    var identifiers: [String] = []
    let exporter = HealthExporter(
      enabled: true, authorizationStatus: { _ in .sharingAuthorized },
      save: { batch in
        identifiers.append(contentsOf: batch.compactMap(self.syncIdentifier))
        await gate.suspendFirstSave()
      })
    let original = try measurement(id: "original")
    let superseded = try measurement(id: "superseded")
    let latest = try measurement(id: "latest")
    let task = Task { await exporter.export([original]) }
    await gate.waitUntilSuspended()
    XCTAssertTrue(exporter.busy)

    await exporter.export([superseded])
    await exporter.export([latest])
    gate.resume()
    await task.value

    XCTAssertEqual(identifiers, ["ourasync.original", "ourasync.latest"])
    XCTAssertFalse(exporter.busy)
  }

  func testPausingDuringSaveStopsRemainingBatchesAndQueuedSnapshot() async throws {
    let previousPreference = UserDefaults.standard.object(forKey: "health.enabled")
    defer { UserDefaults.standard.set(previousPreference, forKey: "health.enabled") }
    let gate = SaveGate()
    var batchSizes: [Int] = []
    let exporter = HealthExporter(
      enabled: true, authorizationStatus: { _ in .sharingAuthorized },
      save: { batch in
        batchSizes.append(batch.count)
        await gate.suspendFirstSave()
      })
    let input = try (0..<1_001).map { try measurement(id: "reading-\($0)") }
    let queued = try measurement(id: "queued")
    let task = Task { await exporter.export(input) }
    await gate.waitUntilSuspended()
    await exporter.export([queued])

    exporter.pause()
    gate.resume()
    await task.value
    await exporter.export([queued])

    XCTAssertEqual(batchSizes, [500])
    XCTAssertFalse(exporter.enabled)
    XCTAssertFalse(exporter.busy)
    XCTAssertTrue(exporter.status.hasPrefix("Export paused"))
  }

  func testCancellationDuringSaveStopsRemainingBatchesAndLeavesExportRetryable() async throws {
    let gate = SaveGate()
    var batchSizes: [Int] = []
    let exporter = HealthExporter(
      enabled: true, authorizationStatus: { _ in .sharingAuthorized },
      save: { batch in
        batchSizes.append(batch.count)
        await gate.suspendFirstSave()
      })
    let input = try (0..<1_001).map { try measurement(id: "reading-\($0)") }
    let task = Task { await exporter.export(input) }
    await gate.waitUntilSuspended()

    task.cancel()
    gate.resume()
    await task.value

    XCTAssertEqual(batchSizes, [500])
    XCTAssertFalse(exporter.busy)
    XCTAssertTrue(exporter.enabled)
    XCTAssertTrue(exporter.status.hasPrefix("Export pending"))
    await exporter.retryPending()
    XCTAssertEqual(batchSizes, [500, 500, 500, 1])
  }

  func testFailedSaveRetriesWithoutAnotherRingSnapshot() async throws {
    var attempts = 0
    let exporter = HealthExporter(
      enabled: true, authorizationStatus: { _ in .sharingAuthorized },
      save: { _ in
        attempts += 1
        if attempts == 1 { throw CocoaError(.fileWriteUnknown) }
      })
    await exporter.export([try measurement(id: "saved-before-disconnect")])
    XCTAssertEqual(attempts, 1)
    await exporter.retryPending()
    XCTAssertEqual(attempts, 2)
    await exporter.retryPending()
    XCTAssertEqual(attempts, 2)
  }

  func testRestoredPermissionsRetrySavedMeasurementsWithoutBluetooth() async throws {
    var permitted = false
    var saves = 0
    let exporter = HealthExporter(
      enabled: true,
      authorizationStatus: { _ in permitted ? .sharingAuthorized : .sharingDenied },
      save: { _ in saves += 1 })
    await exporter.export([try measurement(id: "permission-restored")])
    XCTAssertEqual(saves, 0)
    permitted = true
    await exporter.retryPending()
    XCTAssertEqual(saves, 1)
  }

  func testNewlyGrantedTypeExportsCachedReadingsWithoutAnotherRingSync() async throws {
    var respirationAllowed = false
    var identifiers: [String] = []
    let exporter = HealthExporter(
      enabled: true,
      authorizationStatus: { type in
        type == HKQuantityType(.heartRate)
          || (respirationAllowed && type == HKQuantityType(.respiratoryRate))
          ? .sharingAuthorized : .sharingDenied
      },
      save: { identifiers.append(contentsOf: $0.compactMap(self.syncIdentifier)) })
    let readings = try [
      measurement(id: "heart"), measurement(id: "respiration", kind: .respiratoryRate, value: 15),
    ]
    await exporter.export(readings)
    XCTAssertEqual(identifiers, ["ourasync.heart"])
    respirationAllowed = true
    await exporter.retryPending(cachedMeasurements: readings)
    XCTAssertEqual(identifiers, ["ourasync.heart", "ourasync.heart", "ourasync.respiration"])
    await exporter.retryPending(cachedMeasurements: readings)
    XCTAssertEqual(identifiers.count, 3)
  }

  func testCompletedExportsAreSkippedAfterExporterAndJournalRestart() async throws {
    let url = try temporaryJournalURL()
    let readings = [try measurement(id: "persisted")]
    var saved: [HKSample] = []
    do {
      let journal = try EventStore(url: url)
      let exporter = HealthExporter(
        enabled: true, authorizationStatus: { _ in .sharingAuthorized },
        save: { saved.append(contentsOf: $0) })
      await exporter.export(readings, journal: journal)
    }
    let reopened = try EventStore(url: url)
    let restarted = HealthExporter(
      enabled: true, authorizationStatus: { _ in .sharingAuthorized },
      save: { saved.append(contentsOf: $0) })
    await restarted.export(readings, journal: reopened)
    XCTAssertEqual(saved.compactMap(syncIdentifier), ["ourasync.persisted"])
  }

  func testCorrectedReadingRetainsIdentityAndIncreasesHealthVersion() async throws {
    let journal = try EventStore(url: temporaryJournalURL())
    var saved: [HKSample] = []
    let exporter = HealthExporter(
      enabled: true, authorizationStatus: { _ in .sharingAuthorized },
      save: { saved.append(contentsOf: $0) })
    await exporter.export([try measurement(id: "corrected")], journal: journal)
    let correction = try measurement(id: "corrected", value: 72, start: 800_001_000)
    await exporter.export([correction], journal: journal)
    XCTAssertEqual(saved.compactMap(syncIdentifier), ["ourasync.corrected", "ourasync.corrected"])
    let initialVersion = try XCTUnwrap(saved.first?.metadata?[HKMetadataKeySyncVersion] as? Int)
    let corrected = try XCTUnwrap(saved.last as? HKQuantitySample)
    XCTAssertGreaterThan(
      try XCTUnwrap(corrected.metadata?[HKMetadataKeySyncVersion] as? Int), initialVersion)
    XCTAssertEqual(corrected.startDate, correction.start)
    XCTAssertEqual(corrected.endDate, correction.end)
    XCTAssertEqual(corrected.quantity.doubleValue(for: .count().unitDivided(by: .minute())), 72)
  }

  func testFailedBatchRetriesUnsavedReadingsWithoutRepeatingCompletedBatch() async throws {
    let journal = try EventStore(url: temporaryJournalURL())
    let readings = try (0..<1_001).map { try measurement(id: "batch-\($0)") }
    var attempts: [[HKSample]] = []
    var saved: [HKSample] = []
    let exporter = HealthExporter(
      enabled: true, authorizationStatus: { _ in .sharingAuthorized },
      save: { batch in
        attempts.append(batch)
        if attempts.count == 2 { throw CocoaError(.fileWriteUnknown) }
        saved.append(contentsOf: batch)
      })
    await exporter.export(readings, journal: journal)
    XCTAssertEqual(saved.count, 500)
    await exporter.retryPending()
    XCTAssertEqual(attempts.map(\.count), [500, 500, 500, 1])
    XCTAssertEqual(saved.compactMap(syncIdentifier), readings.map { "ourasync.\($0.id)" })
    XCTAssertEqual(
      attempts[1].compactMap { $0.metadata?[HKMetadataKeySyncVersion] as? Int },
      attempts[2].compactMap { $0.metadata?[HKMetadataKeySyncVersion] as? Int })
  }

  func testJournalLeavesDeniedTypesPendingUntilPermissionIsGranted() async throws {
    let journal = try EventStore(url: temporaryJournalURL())
    var respirationAllowed = false
    var saved: [String] = []
    let exporter = HealthExporter(
      enabled: true,
      authorizationStatus: { type in
        type == HKQuantityType(.heartRate)
          || (respirationAllowed && type == HKQuantityType(.respiratoryRate))
          ? .sharingAuthorized : .sharingDenied
      },
      save: { saved.append(contentsOf: $0.compactMap(self.syncIdentifier)) })
    let readings = try [
      measurement(id: "heart"), measurement(id: "respiration", kind: .respiratoryRate, value: 15),
    ]
    await exporter.export(readings, journal: journal)
    XCTAssertEqual(saved, ["ourasync.heart"])
    respirationAllowed = true
    await exporter.retryPending(cachedMeasurements: readings)
    XCTAssertEqual(saved, ["ourasync.heart", "ourasync.respiration"])
    await exporter.export(readings, journal: journal)
    XCTAssertEqual(saved.count, 2)
  }

  func testSleepExportMapsStagesAndReplacesShorterNightWithoutDuplicates() async throws {
    let journal = try EventStore(url: temporaryJournalURL())
    var saved: [String: HKSample] = [:]
    var deletions: [String] = []
    let exporter = HealthExporter(
      enabled: true, authorizationStatus: { _ in .sharingAuthorized },
      save: { batch in for sample in batch { saved[self.syncIdentifier(sample)!] = sample } },
      deleteSleepNight: { night in
        deletions.append(night)
        saved = saved.filter { $0.value.metadata?["OuraSyncSleepNight"] as? String != night }
      })
    let original = try sleepPeriod(minutes: 26)
    await exporter.export([], sleepPeriods: [original], journal: journal)
    XCTAssertEqual(saved.count, 52)
    XCTAssertEqual(
      Set(saved.values.compactMap { ($0 as? HKCategorySample)?.value }),
      Set([
        HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
        HKCategoryValueSleepAnalysis.asleepCore.rawValue,
        HKCategoryValueSleepAnalysis.asleepREM.rawValue,
        HKCategoryValueSleepAnalysis.awake.rawValue,
      ]))
    await exporter.export([], sleepPeriods: [original], journal: journal)
    XCTAssertEqual(deletions.count, 1)
    let shorter = try sleepPeriod(minutes: 24)
    XCTAssertEqual(shorter.id, original.id)
    await exporter.export([], sleepPeriods: [shorter], journal: journal)
    XCTAssertEqual(saved.count, 48)
    XCTAssertEqual(deletions.count, 2)
    XCTAssertTrue(saved.values.allSatisfy { $0.endDate <= shorter.end })
    XCTAssertTrue(saved.values.allSatisfy { $0.metadata?[HKMetadataKeySyncVersion] as? Int == 2 })
    await exporter.export([], sleepPeriods: [], journal: journal)
    XCTAssertEqual(saved.count, 48, "An absent/partial snapshot is not authoritative invalidation")
  }

  func testSleepReplacementRetriesDeletionAndPartialSaves() async throws {
    let journal = try EventStore(url: temporaryJournalURL())
    var deletionFails = true
    var saveCalls = 0
    var deletes = 0
    var saved: [String: HKSample] = [:]
    let exporter = HealthExporter(
      enabled: true, authorizationStatus: { _ in .sharingAuthorized },
      save: { batch in
        saveCalls += 1
        if saveCalls == 2 { throw CocoaError(.fileWriteUnknown) }
        for sample in batch { saved[self.syncIdentifier(sample)!] = sample }
      },
      deleteSleepNight: { _ in
        deletes += 1
        if deletionFails { throw CocoaError(.fileWriteUnknown) }
        saved.removeAll()
      })
    let period = try sleepPeriod(minutes: 286)
    await exporter.export([], sleepPeriods: [period], journal: journal)
    XCTAssertEqual(saveCalls, 0)
    deletionFails = false
    await exporter.retryPending()
    XCTAssertEqual(saved.count, 500)
    await exporter.retryPending()
    XCTAssertEqual(saved.count, period.epochs.count)
    XCTAssertEqual(deletes, 3)
    XCTAssertTrue(saved.values.allSatisfy { $0.metadata?[HKMetadataKeySyncVersion] as? Int == 1 })
    await exporter.export([], sleepPeriods: [period], journal: journal)
    XCTAssertEqual(deletes, 3)
  }

  func testSleepPermissionRevocationStopsRemainingBatchesAndRetriesAfterGrant() async throws {
    let journal = try EventStore(url: temporaryJournalURL())
    var allowed = true
    var batchCounts: [Int] = []
    var deletes = 0
    let exporter = HealthExporter(
      enabled: true,
      authorizationStatus: { _ in allowed ? .sharingAuthorized : .sharingDenied },
      save: { batch in
        batchCounts.append(batch.count)
        if batchCounts.count == 1 { allowed = false }
      }, deleteSleepNight: { _ in deletes += 1 })
    let period = try sleepPeriod(minutes: 286)
    await exporter.export([], sleepPeriods: [period], journal: journal)
    XCTAssertEqual(batchCounts, [500])
    XCTAssertEqual(exporter.status, "Sleep export pending: Health write access is off")
    allowed = true
    await exporter.retryPending()
    XCTAssertEqual(batchCounts, [500, 500, 72])
    XCTAssertEqual(deletes, 2)
  }

  func testEstimatedSleepIsNotExported() async throws {
    let journal = try EventStore(url: temporaryJournalURL())
    var saved = 0
    var deleted = 0
    let exporter = HealthExporter(
      enabled: true, authorizationStatus: { _ in .sharingAuthorized },
      save: { saved += $0.count }, deleteSleepNight: { _ in deleted += 1 })
    let period = try sleepPeriod(minutes: 26, finalized: false)
    XCTAssertNotEqual(period.timing, .anchoredToSleepSummary)
    await exporter.export([], sleepPeriods: [period], journal: journal)
    XCTAssertEqual(saved, 0)
    XCTAssertEqual(deleted, 0)
  }

  private func sleepPeriod(minutes: UInt32, finalized: Bool = true) throws -> SleepStagePeriod {
    func bytes(_ value: UInt32) -> [UInt8] {
      (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }
    func event(_ tag: UInt8, _ time: UInt32, _ body: [UInt8]) throws -> RingEvent {
      try RingEvent(packet: Packet(tag: tag, payload: bytes(time) + body))
    }
    let start: UInt32 = 100_000
    let summary = start + (minutes + 1) * 600
    let offset = minutes + 1
    var events = try [
      event(0x42, 80_000, bytes(1_789_998_000)),
      event(0x49, summary, [UInt8(truncatingIfNeeded: offset), UInt8(offset >> 8), 1, 0]),
      event(0x76, summary, bytes(start) + bytes(start + minutes * 600)),
    ]
    let pages = Int((minutes + 25) / 26)
    for page in 0..<pages {
      events.append(
        try event(
          0x5a, summary + 100 + UInt32(page), [UInt8(page)] + Array(repeating: 0x1b, count: 13)))
    }
    if finalized {
      events.append(try event(0x4c, summary + 100 + UInt32(pages), Array(repeating: 0, count: 14)))
    }
    return try XCTUnwrap(
      SleepStages(
        events: events,
        session: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        now: Date(timeIntervalSince1970: 1_790_100_000)
      ).periods.first)
  }

  private func temporaryJournalURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try FileManager.default.removeItem(at: directory) }
    return directory.appendingPathComponent("events.sqlite")
  }

  private func syncIdentifier(_ sample: HKSample) -> String? {
    sample.metadata?[HKMetadataKeySyncIdentifier] as? String
  }

  private func measurement(
    id: String, kind: MeasurementKind = .heartRate, value: Double = 60, start: Double = 800_000_000
  ) throws -> OuraProtocol.Measurement {
    let data = try JSONSerialization.data(withJSONObject: [
      "id": id, "kind": kind.rawValue, "start": start, "end": start + 300, "value": value,
    ])
    return try JSONDecoder().decode(OuraProtocol.Measurement.self, from: data)
  }
}

@MainActor
private final class SaveGate {
  private var saveContinuation: CheckedContinuation<Void, Never>?
  private var observer: CheckedContinuation<Void, Never>?
  private var didSuspend = false

  func suspendFirstSave() async {
    guard !didSuspend else { return }
    didSuspend = true
    await withCheckedContinuation { continuation in
      saveContinuation = continuation
      observer?.resume()
      observer = nil
    }
  }

  func waitUntilSuspended() async {
    if didSuspend { return }
    await withCheckedContinuation { observer = $0 }
  }

  func resume() {
    saveContinuation?.resume()
    saveContinuation = nil
  }
}

extension HealthExporterTests {
  func testPausingSleepReplacementKeepsJournalPendingAndStopsRemainingBatches() async throws {
    let preference = UserDefaults.standard.object(forKey: "health.enabled")
    defer { UserDefaults.standard.set(preference, forKey: "health.enabled") }
    let journal = try EventStore(url: temporaryJournalURL())
    let period = try sleepPeriod(minutes: 286)
    let gate = SaveGate()
    var batches: [Int] = []
    let exporter = HealthExporter(
      enabled: true, authorizationStatus: { _ in .sharingAuthorized },
      save: { samples in
        batches.append(samples.count)
        await gate.suspendFirstSave()
      }, deleteSleepNight: { _ in })
    let task = Task { await exporter.export([], sleepPeriods: [period], journal: journal) }
    await gate.waitUntilSuspended()
    exporter.pause()
    gate.resume()
    await task.value
    XCTAssertEqual(batches, [500])
    XCTAssertEqual(exporter.status, "Export paused. Existing Health data is unchanged.")
    let pending = try await journal.prepareSleepHealthExport(period)
    XCTAssertNotNil(pending)
    await exporter.retryPending()
    XCTAssertEqual(batches, [500])
  }
}
