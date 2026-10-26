import Foundation
import Testing

@testable import OuraProtocol

@Test func lowBatteryAlertsOnceUntilARealRecharge() throws {
  var policy = RingAlertPolicy()
  #expect({ !policy.needsBatteryAlert(percent: 21) }())
  #expect({ policy.needsBatteryAlert(percent: 20) }())
  policy.didScheduleBatteryAlert()
  #expect({ !policy.needsBatteryAlert(percent: 19) }())
  #expect({ !policy.needsBatteryAlert(percent: 0) }())
  #expect({ !policy.needsBatteryAlert(percent: 29) }())
  #expect({ !policy.needsBatteryAlert(percent: 20) }())
  #expect({ !policy.needsBatteryAlert(percent: 30) }())
  #expect({ policy.needsBatteryAlert(percent: 20) }())
  policy.didScheduleBatteryAlert()
  let restored = try JSONDecoder().decode(RingAlertPolicy.self, from: JSONEncoder().encode(policy))
  #expect(restored.lowBatteryNotified)
}

@Test func failedSchedulingCanRetryAndInvalidBatteryCannotRearm() {
  var policy = RingAlertPolicy()
  #expect({ policy.needsBatteryAlert(percent: 10) }())
  #expect({ policy.needsBatteryAlert(percent: 10) }())
  policy.didScheduleBatteryAlert()
  #expect({ !policy.needsBatteryAlert(percent: 101) }())
  #expect({ !policy.needsBatteryAlert(percent: -1) }())
  #expect({ !policy.needsBatteryAlert(percent: 10) }())
}

@Test func backgroundReminderIsRateLimitedAndQuickReturnsCancelIt() {
  var policy = RingAlertPolicy()
  let now = Date(timeIntervalSince1970: 1_790_000_000)
  #expect(policy.needsBackgroundReminder(now: now))
  policy.didScheduleBackgroundReminder(deliveryDate: now.addingTimeInterval(10))
  #expect(!policy.needsBackgroundReminder(now: now.addingTimeInterval(5)))
  policy.returnedBeforeReminder(now: now.addingTimeInterval(5))
  #expect(policy.needsBackgroundReminder(now: now.addingTimeInterval(6)))
  policy.didScheduleBackgroundReminder(deliveryDate: now.addingTimeInterval(20))
  policy.returnedBeforeReminder(now: now.addingTimeInterval(21))
  #expect(!policy.needsBackgroundReminder(now: now.addingTimeInterval(3600)))
  #expect(policy.needsBackgroundReminder(now: now.addingTimeInterval(86420)))
}
