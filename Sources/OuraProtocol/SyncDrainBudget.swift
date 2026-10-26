import Foundation

public struct SyncDrainBudget {
  private var backgroundStarted: TimeInterval?
  private let backgroundLimit: TimeInterval

  public init(backgroundLimit: TimeInterval = 25) { self.backgroundLimit = backgroundLimit }

  /// Uptime is monotonic; changes to the phone's wall clock cannot extend a run.
  public mutating func permitsNextBatch(
    uptime: TimeInterval, foreground: Bool, cancelled: Bool
  ) -> Bool {
    guard !cancelled else { return false }
    if foreground {
      backgroundStarted = nil
      return true
    }
    if backgroundStarted == nil { backgroundStarted = uptime }
    return uptime - (backgroundStarted ?? uptime) < backgroundLimit
  }
}
