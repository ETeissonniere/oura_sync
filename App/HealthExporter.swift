import HealthKit
import Observation
import OuraProtocol

@MainActor
@Observable
final class HealthExporter {
  private(set) var enabled: Bool
  private(set) var status = "Not connected"
  private(set) var busy = false
  @ObservationIgnored private let store: HKHealthStore
  @ObservationIgnored private let authorizationStatus:
    @MainActor (HKObjectType) -> HKAuthorizationStatus
  @ObservationIgnored private let save: @MainActor ([HKSample]) async throws -> Void
  @ObservationIgnored private let deleteSleepNight: @MainActor (String) async throws -> Void
  @ObservationIgnored private var pendingMeasurements: [OuraProtocol.Measurement]?
  @ObservationIgnored private var pendingSleepPeriods: [SleepStagePeriod] = []
  @ObservationIgnored private var lastExportPermissions = Set<MeasurementKind>()
  @ObservationIgnored private var journal: EventStore?

  init(
    enabled: Bool? = nil,
    authorizationStatus: (@MainActor (HKObjectType) -> HKAuthorizationStatus)? = nil,
    save: (@MainActor ([HKSample]) async throws -> Void)? = nil,
    deleteSleepNight: (@MainActor (String) async throws -> Void)? = nil
  ) {
    let store = HKHealthStore()
    self.store = store
    self.enabled = enabled ?? UserDefaults.standard.bool(forKey: "health.enabled")
    self.authorizationStatus = authorizationStatus ?? { store.authorizationStatus(for: $0) }
    self.save = save ?? { try await store.save($0) }
    self.deleteSleepNight =
      deleteSleepNight ?? { nightID in
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
          HKQuery.predicateForObjects(from: HKSource.default()),
          HKQuery.predicateForObjects(
            withMetadataKey: "OuraSyncSleepNight", allowedValues: [nightID]),
          HKQuery.predicateForObjects(
            withMetadataKey: "OuraSyncSleepStages", allowedValues: [true]),
        ])
        try await withCheckedThrowingContinuation {
          (continuation: CheckedContinuation<Void, Error>) in
          store.deleteObjects(of: HKCategoryType(.sleepAnalysis), predicate: predicate) {
            success, _, error in
            if let error {
              continuation.resume(throwing: error)
            } else if success {
              continuation.resume()
            } else {
              continuation.resume(throwing: CocoaError(.fileWriteUnknown))
            }
          }
        }
      }
    if self.enabled {
      status = "Waiting to check saved measurements"
    } else if UserDefaults.standard.object(forKey: "health.enabled") != nil {
      status = "Export is off"
    }
  }

  func enable() async {
    guard HKHealthStore.isHealthDataAvailable() else {
      status = "Apple Health is unavailable on this device."
      return
    }
    do {
      try await store.requestAuthorization(toShare: Set(Self.types.values), read: [])
      enabled = Self.types.values.contains {
        authorizationStatus($0) == .sharingAuthorized
      }
      UserDefaults.standard.set(enabled, forKey: "health.enabled")
      status = enabled ? "Ready to export permitted measurements" : "No write permissions granted"
    } catch { status = error.localizedDescription }
  }

  func pause() {
    enabled = false
    pendingMeasurements = nil
    pendingSleepPeriods = []
    UserDefaults.standard.set(false, forKey: "health.enabled")
    status = "Export paused. Existing Health data is unchanged."
  }

  func export(
    _ measurements: [OuraProtocol.Measurement], sleepPeriods: [SleepStagePeriod] = [],
    journal: EventStore? = nil
  ) async {
    guard enabled else { return }
    if let journal { self.journal = journal }
    // A newer snapshot can arrive while HealthKit is saving a previous batch.
    // Keep the latest snapshot instead of silently dropping that sync.
    pendingMeasurements = measurements
    pendingSleepPeriods = sleepPeriods
    guard !busy else { return }
    busy = true
    defer { busy = false }
    do {
      while enabled, let next = pendingMeasurements {
        try Task.checkCancellation()
        pendingMeasurements = nil
        let nextSleep = pendingSleepPeriods
        pendingSleepPeriods = []
        do {
          let exported = try await exportSnapshot(next, sleepPeriods: nextSleep)
          if !exported {
            if enabled && pendingMeasurements == nil {
              pendingMeasurements = next
              pendingSleepPeriods = nextSleep
            }
            break
          }
        } catch {
          if enabled && pendingMeasurements == nil {
            pendingMeasurements = next
            pendingSleepPeriods = nextSleep
          }
          throw error
        }
      }
    } catch {
      if enabled { status = "Export pending: \(error.localizedDescription)" }
    }
  }

  func retryPending(
    cachedMeasurements: [OuraProtocol.Measurement] = [], cachedSleepPeriods: [SleepStagePeriod] = []
  ) async {
    guard enabled else { return }
    if let pendingMeasurements {
      await export(pendingMeasurements, sleepPeriods: pendingSleepPeriods)
    } else if !cachedMeasurements.isEmpty || !cachedSleepPeriods.isEmpty {
      let permitted = Set(
        Self.types.filter {
          authorizationStatus($0.value) == .sharingAuthorized
        }.keys)
      if !permitted.isSubset(of: lastExportPermissions) {
        await export(cachedMeasurements, sleepPeriods: cachedSleepPeriods)
      }
    }
  }

  private func exportSnapshot(
    _ measurements: [OuraProtocol.Measurement], sleepPeriods: [SleepStagePeriod]
  ) async throws -> Bool {
    let journal = self.journal
    let permitted = Self.types.filter {
      authorizationStatus($0.value) == .sharingAuthorized
    }
    lastExportPermissions = Set(permitted.keys)
    guard !permitted.isEmpty else {
      status = "Health write access is off"
      return false
    }
    func sample(_ measurement: OuraProtocol.Measurement, version: Int) -> HKSample? {
      guard let type = permitted[measurement.kind] else { return nil }
      let metadata: [String: Any] = [
        HKMetadataKeySyncIdentifier: "ourasync.\(measurement.id)",
        HKMetadataKeySyncVersion: version,
        "OuraSyncSource": "Ring firmware history",
      ]
      if let quantityType = type as? HKQuantityType {
        let unit: HKUnit
        let value: Double
        switch measurement.kind {
        case .heartRate, .respiratoryRate:
          unit = .count().unitDivided(by: .minute())
          value = measurement.value
        case .hrvRMSSD:
          unit = .secondUnit(with: .milli)
          value = measurement.value
        default: return nil
        }
        return HKQuantitySample(
          type: quantityType, quantity: HKQuantity(unit: unit, doubleValue: value),
          start: measurement.start, end: measurement.end, metadata: metadata)
      }
      guard let categoryType = type as? HKCategoryType else { return nil }
      return HKCategorySample(
        type: categoryType, value: HKCategoryValueSleepAnalysis.inBed.rawValue,
        start: measurement.start, end: measurement.end, metadata: metadata)
    }
    var hasExportableReadings = false
    for offset in stride(from: 0, to: measurements.count, by: 500) {
      guard enabled else { return false }
      try Task.checkCancellation()
      let candidates = measurements[offset..<min(offset + 500, measurements.count)].filter {
        permitted[$0.kind] != nil
      }
      if !candidates.isEmpty { hasExportableReadings = true }
      let records = try await journal?.prepareHealthExports(candidates) ?? []
      let batch =
        journal == nil
        ? candidates.compactMap { sample($0, version: 1) }
        : records.compactMap { sample($0.measurement, version: $0.version) }
      if !batch.isEmpty {
        guard enabled else { return false }
        try Task.checkCancellation()
        try await save(batch)
        try await journal?.completeHealthExports(records)
      }
      await Task.yield()
    }
    if permitted[.inBed] != nil, let journal {
      for period in sleepPeriods where period.timing == .anchoredToSleepSummary {
        guard enabled else { return false }
        try Task.checkCancellation()
        hasExportableReadings = true
        guard let record = try await journal.prepareSleepHealthExport(period) else { continue }
        guard mayExportSleep() else { return false }
        // Whole-night replacement also removes obsolete epochs when a revision
        // shrinks. The pending journal makes deletion and partial saves retryable.
        try await deleteSleepNight(period.id)
        for offset in stride(from: 0, to: period.epochs.count, by: 500) {
          guard mayExportSleep() else { return false }
          try Task.checkCancellation()
          let batch = period.epochs[offset..<min(offset + 500, period.epochs.count)].map {
            Self.sleepSample($0, nightID: period.id, version: record.version)
          }
          try await save(batch)
        }
        try await journal.completeSleepHealthExport(record)
      }
    }
    if enabled {
      status =
        hasExportableReadings
        ? "Permitted Health data is up to date" : "Waiting for dated measurements"
    }
    return enabled
  }

  private func mayExportSleep() -> Bool {
    guard enabled else { return false }
    guard authorizationStatus(HKCategoryType(.sleepAnalysis)) == .sharingAuthorized else {
      status = "Sleep export pending: Health write access is off"
      return false
    }
    return true
  }

  private static func sleepSample(_ epoch: SleepStageEpoch, nightID: String, version: Int)
    -> HKCategorySample
  {
    let value: HKCategoryValueSleepAnalysis
    switch epoch.stage {
    case .deep: value = .asleepDeep
    case .light: value = .asleepCore
    case .rem: value = .asleepREM
    case .awake: value = .awake
    }
    return HKCategorySample(
      type: HKCategoryType(.sleepAnalysis), value: value.rawValue,
      start: epoch.start, end: epoch.end,
      metadata: [
        HKMetadataKeySyncIdentifier: "ourasync.\(epoch.id)",
        HKMetadataKeySyncVersion: version,
        "OuraSyncSource": "Ring firmware history",
        "OuraSyncSleepNight": nightID,
        "OuraSyncSleepStages": true,
      ])
  }

  static var types: [MeasurementKind: HKSampleType] {
    // Ring oxygen bytes lack verified calibration, so they must not enter Health.
    var types: [MeasurementKind: HKSampleType] = [
      .heartRate: HKQuantityType(.heartRate),
      .respiratoryRate: HKQuantityType(.respiratoryRate),
      .inBed: HKCategoryType(.sleepAnalysis),
    ]
    if #available(iOS 27, *) { types[.hrvRMSSD] = HKQuantityType(.heartRateVariabilityRMSSD) }
    return types
  }
}
