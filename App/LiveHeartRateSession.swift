import Foundation
import Observation
import OuraProtocol

@MainActor
@Observable
final class LiveHeartRateSession {
  private(set) var running = false
  private(set) var stopping = false
  private(set) var status = "Ready for a live reading"
  private(set) var error: String?
  private(set) var latest: LiveHeartRateReading?
  private(set) var receivedAt: Date?
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var acceptingReadings = false
  @ObservationIgnored private let duration: Duration

  init(duration: Duration = .seconds(60)) { self.duration = duration }

  @discardableResult
  func start(
    prepare: @escaping @MainActor () async throws -> Void,
    enable: @escaping @MainActor () async throws -> Void,
    restore: @escaping @MainActor () async throws -> Void,
    didFinish: @escaping @MainActor () -> Void
  ) -> Bool {
    guard task == nil else { return false }
    running = true
    stopping = false
    error = nil
    latest = nil
    receivedAt = nil
    status = "Connecting for a live reading…"
    task = Task { [self] in
      var enableAttempted = false
      do {
        try Task.checkCancellation()
        try await prepare()
        try Task.checkCancellation()
        enableAttempted = true
        try await enable()
        try Task.checkCancellation()
        acceptingReadings = true
        status = "Waiting for a reading…"
        try await Task.sleep(for: duration)
      } catch {
        if !Task.isCancelled { self.error = error.localizedDescription }
      }
      acceptingReadings = false
      stopping = true
      if enableAttempted {
        status = "Restoring automatic recording…"
        // Cleanup must survive cancellation of the live session. Keep ownership
        // until this fresh task restores automatic mode or reports its failure.
        let cleanup = Task { @MainActor in try await restore() }
        do {
          try await cleanup.value
        } catch {
          let failure = "Automatic recording could not be restored: \(error.localizedDescription)"
          self.error = self.error.map { "\($0) \(failure)" } ?? failure
        }
      }
      status =
        error != nil
        ? "Live reading needs attention"
        : latest == nil ? "No valid reading received" : "Live reading finished"
      running = false
      stopping = false
      task = nil
      didFinish()
    }
    return true
  }

  func stop() {
    guard running else { return }
    stopping = true
    acceptingReadings = false
    task?.cancel()
  }

  func receive(_ reading: LiveHeartRateReading, at date: Date = .now) {
    guard acceptingReadings else { return }
    latest = reading
    receivedAt = date
    status = "Measuring · keep your hand still"
  }
}
