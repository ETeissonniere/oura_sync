import Observation
import OuraProtocol
import UIKit
import UserNotifications

@MainActor
@Observable
final class RingNotifications: NSObject, UNUserNotificationCenterDelegate {
  static let shared = RingNotifications()
  var lowBatteryEnabled = UserDefaults.standard.object(forKey: "alerts.lowBattery") as? Bool ?? true
  {
    didSet {
      UserDefaults.standard.set(lowBatteryEnabled, forKey: "alerts.lowBattery")
      if !lowBatteryEnabled {
        center.removePendingNotificationRequests(withIdentifiers: [Self.batteryID])
      }
    }
  }
  var backgroundReminderEnabled =
    UserDefaults.standard.object(forKey: "alerts.background") as? Bool ?? true
  {
    didSet {
      UserDefaults.standard.set(backgroundReminderEnabled, forKey: "alerts.background")
      if !backgroundReminderEnabled {
        center.removePendingNotificationRequests(withIdentifiers: [Self.reminderID])
      }
    }
  }
  private(set) var permissionGranted = false
  private(set) var permissionDenied = false
  private(set) var status = "Allow notifications to receive ring alerts."
  @ObservationIgnored private let center = UNUserNotificationCenter.current()
  @ObservationIgnored private var policies: [String: RingAlertPolicy] = [:]
  nonisolated private static let batteryID = "ourasync.low-battery"
  nonisolated private static let reminderID = "ourasync.background-reminder"

  override private init() {
    super.init()
    if let data = UserDefaults.standard.data(forKey: "alerts.policies"),
      let saved = try? JSONDecoder().decode([String: RingAlertPolicy].self, from: data)
    {
      policies = saved
    }
    center.delegate = self
  }

  func requestPermission() async {
    do {
      _ = try await center.requestAuthorization(options: [.alert, .sound])
      await refreshPermission()
    } catch { status = error.localizedDescription }
  }

  func refreshPermission() async {
    let settings = await center.notificationSettings()
    permissionGranted = [.authorized, .provisional, .ephemeral].contains(
      settings.authorizationStatus)
    permissionDenied = settings.authorizationStatus == .denied
    status =
      permissionGranted
      ? "Notifications allowed"
      : permissionDenied
        ? "Notifications are off in iPhone Settings."
        : "Allow notifications to receive ring alerts."
  }

  func receivedBattery(_ percent: Int, ringID: UUID) async {
    let key = ringID.uuidString
    var policy = policies[key] ?? RingAlertPolicy()
    let needed = policy.needsBatteryAlert(percent: percent)
    policies[key] = policy
    persist()
    if percent >= 30 {
      center.removePendingNotificationRequests(withIdentifiers: [Self.batteryID])
      center.removeDeliveredNotifications(withIdentifiers: [Self.batteryID])
    }
    guard needed, lowBatteryEnabled else { return }
    await refreshPermission()
    guard permissionGranted, lowBatteryEnabled else { return }
    let content = UNMutableNotificationContent()
    content.title = "Time to charge your ring"
    content.body =
      "Your ring reported \(percent)% battery. Place it on its charger to keep recording."
    content.sound = .default
    do {
      try await center.add(
        UNNotificationRequest(identifier: Self.batteryID, content: content, trigger: nil))
      if !lowBatteryEnabled {
        center.removePendingNotificationRequests(withIdentifiers: [Self.batteryID])
        return
      }
      policies[key, default: RingAlertPolicy()].didScheduleBatteryAlert()
      persist()
    } catch { status = "Battery alert could not be scheduled: \(error.localizedDescription)" }
  }

  func enteredBackground(ringID: UUID) async {
    guard backgroundReminderEnabled else { return }
    let key = ringID.uuidString
    let now = Date.now
    let policy = policies[key] ?? RingAlertPolicy()
    guard policy.needsBackgroundReminder(now: now) else { return }
    await refreshPermission()
    guard permissionGranted, backgroundReminderEnabled,
      UIApplication.shared.applicationState != .active,
      (policies[key] ?? RingAlertPolicy()).needsBackgroundReminder(now: .now)
    else { return }
    let content = UNMutableNotificationContent()
    content.title = "Keep Oura Sync in the background"
    content.body =
      "You can use other apps or lock your iPhone. Leave Oura Sync in the app switcher so iOS can reconnect to your ring."
    do {
      try await center.add(
        UNNotificationRequest(
          identifier: Self.reminderID, content: content,
          trigger: UNTimeIntervalNotificationTrigger(timeInterval: 10, repeats: false)))
      guard backgroundReminderEnabled, UIApplication.shared.applicationState != .active else {
        center.removePendingNotificationRequests(withIdentifiers: [Self.reminderID])
        return
      }
      policies[key, default: RingAlertPolicy()].didScheduleBackgroundReminder(
        deliveryDate: Date.now.addingTimeInterval(10))
      persist()
    } catch { status = "Background reminder could not be scheduled: \(error.localizedDescription)" }
  }

  func becameActive(ringID: UUID?) async {
    center.removePendingNotificationRequests(withIdentifiers: [Self.reminderID])
    if let ringID {
      policies[ringID.uuidString]?.returnedBeforeReminder(now: .now)
      persist()
    }
    await refreshPermission()
  }

  private func persist() {
    if let data = try? JSONEncoder().encode(policies) {
      UserDefaults.standard.set(data, forKey: "alerts.policies")
    }
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    notification.request.identifier == Self.batteryID ? [.banner, .sound] : []
  }
}
