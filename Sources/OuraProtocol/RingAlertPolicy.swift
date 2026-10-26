import Foundation

public struct RingAlertPolicy: Codable, Sendable {
  public private(set) var lowBatteryNotified = false
  public private(set) var lastBackgroundReminder: Date?

  public init() {}

  public mutating func needsBatteryAlert(percent: Int) -> Bool {
    guard (0...100).contains(percent) else { return false }
    if percent >= 30 { lowBatteryNotified = false }
    return percent <= 20 && !lowBatteryNotified
  }

  public mutating func didScheduleBatteryAlert() { lowBatteryNotified = true }

  public func needsBackgroundReminder(now: Date) -> Bool {
    guard let lastBackgroundReminder else { return true }
    return now.timeIntervalSince(lastBackgroundReminder) >= 24 * 60 * 60
  }

  public mutating func didScheduleBackgroundReminder(deliveryDate: Date) {
    lastBackgroundReminder = deliveryDate
  }

  public mutating func returnedBeforeReminder(now: Date) {
    if let lastBackgroundReminder, lastBackgroundReminder > now {
      self.lastBackgroundReminder = nil
    }
  }
}
