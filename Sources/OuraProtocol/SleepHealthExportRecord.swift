import Foundation

public struct SleepHealthExportRecord: Sendable {
  public let period: SleepStagePeriod
  public let version: Int

  public init(period: SleepStagePeriod, version: Int) {
    self.period = period
    self.version = version
  }
}
