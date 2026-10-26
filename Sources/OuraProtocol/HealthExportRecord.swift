import Foundation

public struct HealthExportRecord: Sendable, Equatable {
  public let measurement: Measurement
  public let version: Int

  public init(measurement: Measurement, version: Int) {
    self.measurement = measurement
    self.version = version
  }
}
