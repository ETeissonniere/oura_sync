#if DEBUG && targetEnvironment(simulator)
  import SwiftUI
  import UserNotifications

  struct NotificationDeliveryPreview: View {
    @State private var alerts = RingNotifications.shared
    @State private var ringID = UUID()
    @State private var delivered: [UNNotification] = []
    @State private var reminders: [UNNotification] = []
    @State private var pendingReminders = 0
    @State private var lastBackgroundPending = 0
    @State private var transitions = ""
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          Text("Simulator notification delivery").font(.title2)
          Text(alerts.status)
          Button("Request notification permission") { Task { await alerts.requestPermission() } }
          ForEach([20, 19, 30], id: \.self) { percent in
            Button("Report \(percent)% battery") {
              Task {
                await alerts.receivedBattery(percent, ringID: ringID)
                await refresh()
              }
            }
          }
          Button("Refresh delivered alerts") { Task { await refresh() } }
          Text(transitions).accessibilityIdentifier("sceneTransitions")
          Text("Pending reminders: \(pendingReminders)")
          Text("Last background pending: \(lastBackgroundPending)")
          Text("Delivered reminders: \(reminders.count)")
          ForEach(reminders, id: \.request.identifier) { notification in
            Text(notification.request.content.title)
            Text(notification.request.content.body)
            Text(
              notification.date.timeIntervalSince1970.formatted(
                .number.precision(.fractionLength(3)))
            )
            .accessibilityIdentifier("reminderTimestamp")
          }
          Text("Delivered: \(delivered.count)")
          ForEach(delivered, id: \.request.identifier) { notification in
            Text(notification.request.content.title)
            Text(notification.request.content.body)
            Text(
              notification.date.timeIntervalSince1970.formatted(
                .number.precision(.fractionLength(3)))
            )
            .accessibilityIdentifier("deliveredTimestamp")
          }
        }.padding(24)
      }
      .task {
        alerts.lowBatteryEnabled = true
        alerts.backgroundReminderEnabled = true
        await alerts.refreshPermission()
      }
      .onChange(of: scenePhase) { _, phase in
        transitions += "\(phase)/\(UIApplication.shared.applicationState.rawValue) "
        Task {
          if phase == .background {
            await alerts.enteredBackground(ringID: ringID)
            await refresh()
            lastBackgroundPending = pendingReminders
            transitions += "scheduled:\(pendingReminders)/\(alerts.status) "
          } else if phase == .active {
            await alerts.becameActive(ringID: ringID)
            await refresh()
          }
        }
      }
    }

    private func refresh() async {
      let center = UNUserNotificationCenter.current()
      let notifications = await center.deliveredNotifications()
      delivered = notifications.filter { $0.request.identifier == "ourasync.low-battery" }
      reminders = notifications.filter { $0.request.identifier == "ourasync.background-reminder" }
      pendingReminders = await center.pendingNotificationRequests()
        .filter { $0.identifier == "ourasync.background-reminder" }.count
    }
  }
#endif
