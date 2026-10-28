import BackgroundTasks
import UIKit

@MainActor
final class BackgroundSync: NSObject, UIApplicationDelegate {
  private static let identifier = "app.ourasync.refresh"
  private static var scheduling = false

  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    let ring = RingCoordinator.shared
    if ring.pairing?.confirmed == true {
      ring.startBluetooth()
      Self.schedule()
    }
    BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.identifier, using: .main) { task in
      Task { @MainActor in
        Self.schedule()
        let operation = Task { @MainActor in
          async let healthRetry: Void = ring.retryHealthExport()
          let completed = await ring.sync()
          await healthRetry
          task.setTaskCompleted(success: completed && !Task.isCancelled)
        }
        task.expirationHandler = {
          operation.cancel()
        }
      }
    }
    return true
  }

  static func schedule() {
    guard RingCoordinator.shared.pairing?.confirmed == true, !scheduling else { return }
    scheduling = true
    BGTaskScheduler.shared.getPendingTaskRequests { requests in
      let identifiers = requests.map(\.identifier)
      Task { @MainActor in
        defer { scheduling = false }
        guard RingCoordinator.shared.pairing?.confirmed == true else { return }
        // Replacing this request on every Bluetooth wake moves its earliest
        // start forward indefinitely. Keep the already queued opportunity.
        guard !identifiers.contains(identifier) else { return }
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
          try BGTaskScheduler.shared.submit(request)
          RingCoordinator.shared.setBackgroundStatus("Enabled · timing managed by iOS")
        } catch {
          RingCoordinator.shared.setBackgroundStatus("Bluetooth enabled; app refresh unavailable")
        }
      }
    }
  }
}
