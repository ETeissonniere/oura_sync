import SwiftUI

struct NotificationSettingsView: View {
  @Bindable private var alerts = RingNotifications.shared

  var body: some View {
    DisclosureGroup("Ring notifications") {
      VStack(alignment: .leading, spacing: 14) {
        Toggle("Low-battery alerts", isOn: $alerts.lowBatteryEnabled)
        Text(
          "A reminder at 20% or below. Another alert becomes available after your ring reaches 30% again. Alerts use battery readings received during sync."
        )
        .font(.caption).foregroundStyle(Color.secondaryInk)
        Toggle("Background-sync reminder", isOn: $alerts.backgroundReminderEnabled)
        Text(
          "At most once a day after you leave the app. You can lock your phone or use other apps; avoid swiping Oura Sync away. iOS does not let us reliably detect a force-quit."
        )
        .font(.caption).foregroundStyle(Color.secondaryInk)
        Text(alerts.status).font(.caption).foregroundStyle(Color.secondaryInk)
        if alerts.permissionDenied {
          Link(
            "Open notification settings",
            destination: URL(string: UIApplication.openSettingsURLString)!)
        } else if !alerts.permissionGranted {
          Button("Allow notifications") { Task { await alerts.requestPermission() } }
        }
      }.font(.subheadline).padding(.top, 12)
    }
    .task { await alerts.refreshPermission() }
  }
}
