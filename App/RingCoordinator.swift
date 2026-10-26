import Foundation
import Observation
import OuraProtocol
import UIKit

@MainActor
@Observable
final class RingCoordinator {
  static let shared = RingCoordinator()
  struct Pairing: Codable {
    let peripheralID: UUID
    let session: UUID
    var confirmed: Bool
    var measurementsConfigured: Bool?
    var automaticRecordingNeedsRestore: Bool?
  }

  private(set) var transport: RingTransport?
  private(set) var pairing: Pairing?
  private(set) var busy = false
  private(set) var message = "Connect your ring to begin."
  private(set) var error: String?
  private(set) var battery: Int?
  private(set) var lastSync: Date?
  private(set) var syncedEvents = 0
  private(set) var historySyncEvidence = HistorySyncProgress()
  private(set) var backgroundStatus = "Waiting for setup"
  private(set) var oxygenRecordingStatus = "Pending ring verification"
  private(set) var daytimeHeartRateStatus = "Pending ring verification"
  @ObservationIgnored private var lastAutomaticAttempt = Date.distantPast
  @ObservationIgnored private var automaticSyncPending = false
  @ObservationIgnored private var automaticSyncTask: Task<Void, Never>?
  private(set) var measurements: [OuraProtocol.Measurement] = []
  private(set) var sleepPeriods: [SleepStagePeriod] = []
  private(set) var nightlyVitals: [NightlyVitals] = []
  private(set) var undatedEvents = 0
  let health = HealthExporter()
  let liveHeartRate = LiveHeartRateSession()
  @ObservationIgnored private var liveCleanupTask: UIBackgroundTaskIdentifier = .invalid
  @ObservationIgnored private var store: EventStore?
  @ObservationIgnored private var refreshGeneration = 0
  @ObservationIgnored private let keys = PairingKeyStore()
  @ObservationIgnored private let pairingKey = "ring.pairing"

  init() {
    if let data = UserDefaults.standard.data(forKey: pairingKey) {
      do { pairing = try JSONDecoder().decode(Pairing.self, from: data) } catch {
        self.error =
          "Saved ring setup could not be read. Please contact support before resetting your ring."
      }
    }
    lastSync = UserDefaults.standard.object(forKey: "ring.lastSync") as? Date
    if let data = UserDefaults.standard.data(forKey: "ring.historySyncEvidence"),
      let evidence = try? JSONDecoder().decode(HistorySyncProgress.self, from: data)
    {
      historySyncEvidence = evidence
    }
    if pairing?.automaticRecordingNeedsRestore == true {
      daytimeHeartRateStatus = "Automatic recording needs restoration. Sync your ring to retry."
    } else if pairing?.measurementsConfigured == true {
      daytimeHeartRateStatus = "Automatic recording enabled"
    }
  }

  func startBluetooth() {
    guard transport == nil else { return }
    let transport = RingTransport()
    self.transport = transport
    transport.onRestoredConnection = { [weak self] in
      self?.automaticSync()
    }
    transport.onHistoryAvailable = { [weak self] in self?.automaticSync() }
    transport.onLiveHeartRate = { [weak self] readings in
      for reading in readings { self?.liveHeartRate.receive(reading) }
    }
    if let pairing, pairing.confirmed {
      transport.maintainConnection(to: pairing.peripheralID)
      backgroundStatus = "Bluetooth reconnection enabled"
    }
  }

  func automaticSync() {
    guard pairing?.confirmed == true else { return }
    automaticSyncPending = true
    scheduleAutomaticSync()
  }

  private func scheduleAutomaticSync() {
    guard automaticSyncPending, !busy, automaticSyncTask == nil else { return }
    let delay = max(0, 60 - Date.now.timeIntervalSince(lastAutomaticAttempt))
    automaticSyncTask = Task { [weak self] in
      if delay > 0 {
        do { try await Task.sleep(for: .seconds(delay)) } catch { return }
      }
      guard !Task.isCancelled, let self else { return }
      self.automaticSyncTask = nil
      // A delayed task is not a background execution grant. Retain the pending
      // work for the next Bluetooth wake, app refresh, or foreground activation.
      if delay > 0 && UIApplication.shared.applicationState != .active {
        BackgroundSync.schedule()
        return
      }
      await self.sync()
    }
  }

  private func endOperation(resumeAfterCancellation: Bool = false) {
    busy = false
    if Task.isCancelled && !resumeAfterCancellation {
      automaticSyncPending = true
      automaticSyncTask?.cancel()
      automaticSyncTask = nil
    } else {
      scheduleAutomaticSync()
    }
  }

  func setBackgroundStatus(_ status: String) { backgroundStatus = status }

  func scan() {
    startBluetooth()
    error = nil
    do { try transport?.scan() } catch { self.error = error.localizedDescription }
  }

  func pair(id: UUID) async {
    guard !busy, let transport else { return }
    busy = true
    lastAutomaticAttempt = .now
    error = nil
    defer { endOperation() }
    do {
      message = "Connecting to your ring…"
      try await transport.connect(to: id)
      let key = try keys.existingOrCreate(for: id)
      let client = RingClient(connection: transport)
      message = "Securing your connection…"
      do {
        try await client.authenticate(key: key)
        if pairing?.peripheralID != id {
          beginPairingSession(for: id)
        }
      } catch let failure as RingClient.AuthenticationFailure where failure.status == 2 {
        // Only a confirmed factory-reset response creates a new history epoch.
        // Persist before installing the key so interrupted setup can resume.
        if pairing?.peripheralID != id || pairing?.confirmed == true {
          beginPairingSession(for: id)
          try savePairing()
        }
        try await client.installKey(key)
      }
      daytimeHeartRateStatus =
        pairing?.measurementsConfigured == true
        ? "Automatic recording enabled" : "Pending ring verification"
      oxygenRecordingStatus = "Pending ring verification"
      pairing?.confirmed = true
      try savePairing()
      transport.maintainConnection(to: id)
      backgroundStatus = "Bluetooth reconnection enabled"
      message = "Your ring is paired."
      battery = try await client.battery()
      if let battery { await RingNotifications.shared.receivedBattery(battery, ringID: id) }
      if try await drain(client: client) {
        try await configureMeasurements(client)
        try await configureOxygenRecording(client)
      }
    } catch { self.error = error.localizedDescription }
  }

  private func beginPairingSession(for id: UUID) {
    pairing = Pairing(peripheralID: id, session: UUID(), confirmed: false)
    battery = nil
    lastSync = nil
    UserDefaults.standard.removeObject(forKey: "ring.lastSync")
    historySyncEvidence = HistorySyncProgress()
    UserDefaults.standard.removeObject(forKey: "ring.historySyncEvidence")
    daytimeHeartRateStatus = "Pending ring verification"
    oxygenRecordingStatus = "Pending ring verification"
  }

  @discardableResult
  func sync() async -> Bool {
    guard !Task.isCancelled, let pairing, pairing.confirmed else { return false }
    guard !busy else {
      automaticSyncPending = true
      return false
    }
    startBluetooth()
    guard let transport else { return false }
    busy = true
    automaticSyncPending = false
    automaticSyncTask?.cancel()
    automaticSyncTask = nil
    error = nil
    lastAutomaticAttempt = .now
    defer { endOperation() }
    do {
      guard let key = try keys.load(for: pairing.peripheralID) else {
        throw RingClient.Failure(
          "The saved ring key is unavailable. No changes have been made to the ring.")
      }
      message = "Connecting…"
      if transport.connectedID != pairing.peripheralID {
        try await transport.connect(to: pairing.peripheralID)
      }
      let client = RingClient(connection: transport)
      try await client.authenticate(key: key)
      if pairing.automaticRecordingNeedsRestore == true {
        try await restoreAutomaticHeartRate(client)
      }
      battery = try await client.battery()
      if let battery {
        await RingNotifications.shared.receivedBattery(battery, ringID: pairing.peripheralID)
      }
      let completed = try await drain(client: client)
      if completed {
        try await configureMeasurements(client)
        try await configureOxygenRecording(client)
      }
      return completed
    } catch {
      self.error = error.localizedDescription
      return false
    }
  }

  private func configureMeasurements(_ client: RingClient) async throws {
    guard pairing?.measurementsConfigured != true else { return }
    do {
      try await client.enableDaytimeHeartRate()
      pairing?.measurementsConfigured = true
      try savePairing()
      daytimeHeartRateStatus = "Automatic recording enabled"
    } catch {
      try Task.checkCancellation()
      pairing?.measurementsConfigured = false
      daytimeHeartRateStatus = error.localizedDescription
    }
  }

  func startLiveHeartRate() {
    guard !busy, let pairing, pairing.confirmed else { return }
    startBluetooth()
    guard let transport else { return }
    busy = true
    automaticSyncTask?.cancel()
    automaticSyncTask = nil
    message = "Preparing live heart rate…"
    let client = RingClient(connection: transport)
    liveHeartRate.start(
      prepare: { [self] in
        guard let key = try keys.load(for: pairing.peripheralID) else {
          throw RingClient.Failure("The saved ring key is unavailable. Reconnect and try again.")
        }
        if transport.connectedID != pairing.peripheralID {
          try await transport.connect(to: pairing.peripheralID)
        }
        try await client.authenticate(key: key)
        if self.pairing?.automaticRecordingNeedsRestore == true {
          try await restoreAutomaticHeartRate(client)
        }
      },
      enable: { [self] in
        // Persist before changing the ring so a killed app can restore normal
        // recording on its next authenticated connection.
        self.pairing?.automaticRecordingNeedsRestore = true
        self.pairing?.measurementsConfigured = false
        try savePairing()
        daytimeHeartRateStatus = "Live measurement in progress"
        try await client.enableLiveHeartRate()
      },
      restore: { [self] in
        do {
          if transport.connectedID != pairing.peripheralID {
            try await transport.connect(to: pairing.peripheralID)
          }
          guard let key = try keys.load(for: pairing.peripheralID) else {
            throw RingClient.Failure(
              "The ring key is unavailable. Automatic recording will retry on the next sync.")
          }
          // CoreBluetooth may have reconnected while the live session held
          // command ownership. A connected link is not necessarily authenticated.
          try await client.authenticate(key: key)
          try await restoreAutomaticHeartRate(client)
        } catch {
          daytimeHeartRateStatus = "Automatic recording needs restoration. Sync your ring to retry."
          throw error
        }
      },
      didFinish: { [self] in
        endLiveCleanupTime()
        message = "Live measurement finished."
        automaticSyncPending = true
        // Stopping a foreground measurement cancels its task, not the user's
        // queued sync. Background cancellation still waits for an execution grant.
        endOperation(resumeAfterCancellation: UIApplication.shared.applicationState == .active)
      })
  }

  func stopLiveHeartRate() {
    guard liveHeartRate.running else { return }
    if UIApplication.shared.applicationState != .active, liveCleanupTask == .invalid {
      liveCleanupTask = UIApplication.shared.beginBackgroundTask(withName: "Restore ring recording")
      {
        [weak self] in
        Task { @MainActor in self?.endLiveCleanupTime() }
      }
    }
    liveHeartRate.stop()
  }

  private func endLiveCleanupTime() {
    guard liveCleanupTask != .invalid else { return }
    UIApplication.shared.endBackgroundTask(liveCleanupTask)
    liveCleanupTask = .invalid
  }

  private func restoreAutomaticHeartRate(_ client: RingClient) async throws {
    try await client.enableDaytimeHeartRate()
    pairing?.automaticRecordingNeedsRestore = false
    pairing?.measurementsConfigured = true
    try savePairing()
    daytimeHeartRateStatus = "Automatic recording enabled"
  }

  private func configureOxygenRecording(_ client: RingClient) async throws {
    do {
      try await client.enableOxygenSaturation()
      oxygenRecordingStatus = "Automatic recording enabled"
    } catch {
      try Task.checkCancellation()
      // History is already saved before this optional request, whose timeout
      // may disconnect the ring. Retry oxygen on the next successful sync.
      oxygenRecordingStatus = error.localizedDescription
    }
  }

  private func drain(client: RingClient) async throws -> Bool {
    guard let pairing else { return false }
    let store = try historyStore()
    try await client.prepareSync()
    var cursor = try await store.cursor(session: pairing.session)
    syncedEvents = 0
    var tailPasses = 0
    var budget = SyncDrainBudget()
    var progress = HistorySyncProgress()
    var outcome = HistorySyncProgress.Outcome.failed
    defer {
      progress.finish(Task.isCancelled ? .interrupted : outcome)
      saveSyncEvidence(progress)
    }
    while budget.permitsNextBatch(
      uptime: ProcessInfo.processInfo.systemUptime,
      foreground: UIApplication.shared.applicationState == .active,
      cancelled: Task.isCancelled)
    {
      try Task.checkCancellation()
      let batch = try await client.history(cursor: cursor)
      try await store.commit(batch, session: pairing.session, expectedCursor: cursor)
      syncedEvents += batch.events.count
      let applicationState = UIApplication.shared.applicationState
      if applicationState != .inactive {
        progress.saved(
          events: batch.events.count, at: .now,
          inBackground: applicationState == .background)
      }
      saveSyncEvidence(progress)
      message = "Saved \(syncedEvents.formatted()) measurements"
      if batch.nextCursor == cursor {
        if batch.bytesRemaining > 0 {
          throw RingClient.Failure(
            "The ring has more history but made no progress. Your saved measurements are safe; try syncing again."
          )
        }
        outcome = .upToDate
        await finishSync()
        return true
      }
      cursor = batch.nextCursor
      if batch.bytesRemaining == 0 && batch.events.count < 32 {
        tailPasses += 1
      } else {
        tailPasses = 0
      }
      if tailPasses >= 3 {
        outcome = .upToDate
        await finishSync()
        return true
      }
    }
    try Task.checkCancellation()
    outcome = .saved
    automaticSyncPending = true
    message = "Progress saved. Sync will continue automatically when the app can run."
    await refreshMeasurements()
    return false
  }

  private func saveSyncEvidence(_ progress: HistorySyncProgress) {
    if let foreground = progress.foreground { historySyncEvidence.foreground = foreground }
    if let background = progress.background { historySyncEvidence.background = background }
    if let data = try? JSONEncoder().encode(historySyncEvidence) {
      UserDefaults.standard.set(data, forKey: "ring.historySyncEvidence")
    }
  }

  private func finishSync() async {
    await refreshMeasurements()
    lastSync = .now
    UserDefaults.standard.set(lastSync, forKey: "ring.lastSync")
    message = "Your ring is up to date."
  }

  func retryHealthExport() async {
    if measurements.isEmpty {
      await refreshMeasurements()
    } else {
      await health.retryPending(cachedMeasurements: measurements)
    }
  }

  func refreshMeasurements() async {
    let session = pairing?.session
    refreshGeneration += 1
    let generation = refreshGeneration
    do {
      let store = try historyStore()
      let history = try await store.recordedHistory()
      guard !Task.isCancelled, generation == refreshGeneration,
        self.pairing?.session == session
      else { return }
      measurements = history.measurements
      sleepPeriods = history.sleepPeriods
      nightlyVitals = history.nightlyVitals
      undatedEvents = history.undatedEvents
      await health.export(measurements, journal: store)
    } catch {
      if !Task.isCancelled, generation == refreshGeneration, self.pairing?.session == session {
        self.error = "Could not load saved measurements: \(error.localizedDescription)"
      }
    }
  }

  private func historyStore() throws -> EventStore {
    if let store { return store }
    let directory = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
    )
    .appendingPathComponent("RingHistory", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    let store = try EventStore(url: directory.appendingPathComponent("history.sqlite"))
    self.store = store
    return store
  }

  private func savePairing() throws {
    UserDefaults.standard.set(try JSONEncoder().encode(pairing), forKey: pairingKey)
  }
}
