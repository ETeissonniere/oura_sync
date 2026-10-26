import SwiftUI

struct RingView: View {
  @Environment(RingCoordinator.self) private var ring
  @State private var showSetup = false

  private var paired: Bool { ring.pairing?.confirmed == true }
  private var connected: Bool {
    guard let id = ring.pairing?.peripheralID else { return false }
    return ring.transport?.connectedID == id
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      PageHeading(title: "My ring", subtitle: "Horizon · Gen 3")
      RingStatusHero(
        battery: paired ? ring.battery : nil, paired: paired, connected: connected,
        syncing: ring.busy, lastSync: ring.lastSync)
      if let error = ring.error {
        Text(error).font(.subheadline).foregroundStyle(.red)
          .accessibilityLabel("Ring error: \(error)")
      }
      if paired {
        Button(ring.busy ? "Syncing…" : "Sync now") { Task { await ring.sync() } }
          .buttonStyle(PrimaryButtonStyle()).disabled(ring.busy)
      } else {
        Button("Set up my ring") { showSetup = true }.buttonStyle(PrimaryButtonStyle())
      }
      Surface {
        Label("Apple Health", systemImage: "heart").font(.headline)
        Text(ring.health.status).font(.subheadline).foregroundStyle(Color.secondaryInk)
        Button(ring.health.enabled ? "Review Health permissions" : "Connect Apple Health") {
          Task {
            await ring.health.enable()
            await ring.refreshMeasurements()
          }
        }
        .font(.subheadline).frame(minHeight: 44)
        if ring.health.enabled {
          Button("Pause Apple Health export") { ring.health.pause() }
            .font(.subheadline).frame(minHeight: 44)
        }
        Divider()
        NotificationSettingsView()
      }
      DisclosureGroup("Sync details") {
        VStack(alignment: .leading, spacing: 8) {
          Text(ring.message).font(.subheadline)
          DetailRow(title: "Background sync", value: ring.backgroundStatus)
          DetailRow(title: "Daytime heart rate", value: ring.daytimeHeartRateStatus)
          DetailRow(title: "Blood oxygen", value: ring.oxygenRecordingStatus)
          Text(
            "iOS chooses when background sync runs. Keep Bluetooth on and leave Oura Sync in the app switcher."
          )
          .font(.caption).foregroundStyle(Color.secondaryInk)
          if ring.undatedEvents > 0 {
            Text(
              "\(ring.undatedEvents) measurements are waiting for a ring clock reference before they can be sent to Health."
            )
            .font(.caption).foregroundStyle(Color.secondaryInk)
          }
          Text("Your history is stored on this iPhone.")
            .font(.caption).foregroundStyle(Color.secondaryInk)
        }.padding(.top, 12)
      }
      if paired {
        DisclosureGroup("Ring setup and recovery") {
          Text(
            "Use setup after resetting a ring or when connecting a different ring. Your history stays on this phone."
          )
          .font(.caption).foregroundStyle(Color.secondaryInk).padding(.vertical, 8)
          Button("Open ring setup") { showSetup = true }
            .font(.subheadline).frame(minHeight: 44)
        }
      }
    }
    .sheet(isPresented: $showSetup) { OnboardingView().environment(ring) }
  }
}

struct RingStatusHero: View {
  let battery: Int?
  let paired: Bool
  let connected: Bool
  let syncing: Bool
  let lastSync: Date?

  private var connectionLabel: String {
    if syncing { return "Syncing" }
    if connected { return "Connected" }
    return paired ? "Disconnected" : "Ready to connect"
  }

  var body: some View {
    VStack(spacing: 18) {
      RingIllustration(battery: battery, active: syncing || connected)
      Label(connectionLabel, systemImage: syncing ? "arrow.triangle.2.circlepath" : "circle.fill")
        .font(.subheadline.weight(.medium))
        .foregroundStyle(connected || syncing ? Color.forest : Color.secondaryInk)
      if paired, let lastSync {
        Text("Last synced \(lastSync.formatted(date: .abbreviated, time: .shortened))")
          .font(.caption).foregroundStyle(Color.secondaryInk)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 12)
  }
}

#if DEBUG && targetEnvironment(simulator)
  struct RingStatusPreview: View {
    var body: some View {
      ScrollView {
        VStack(spacing: 28) {
          PageHeading(title: "My ring", subtitle: "Simulated connection states")
          RingStatusHero(battery: 82, paired: true, connected: true, syncing: false, lastSync: .now)
          Divider()
          RingStatusHero(battery: 36, paired: true, connected: true, syncing: true, lastSync: nil)
          Divider()
          RingStatusHero(
            battery: nil, paired: true, connected: false, syncing: false, lastSync: nil)
        }.padding(24)
      }.background(Color.paper).foregroundStyle(Color.ink)
    }
  }
#endif

struct RingIllustration: View {
  var battery: Int? = nil
  var active = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @ScaledMetric(relativeTo: .title) private var diameter: CGFloat = 180

  var body: some View {
    TimelineView(.animation(minimumInterval: 1 / 30, paused: !active || reduceMotion)) { context in
      let rotation =
        active && !reduceMotion
        ? context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 12) / 12 * 360
        : 0
      ZStack {
        Circle().stroke(Color.forest.opacity(0.1), lineWidth: 12)
        if let battery {
          Circle().trim(from: 0, to: CGFloat(min(max(battery, 0), 100)) / 100)
            .stroke(Color.forest, style: StrokeStyle(lineWidth: 12, lineCap: .round))
            .rotationEffect(.degrees(-90))
        }
        if active {
          Circle().trim(from: 0, to: 0.15)
            .stroke(Color.forest.opacity(0.45), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .padding(-12).rotationEffect(.degrees(rotation))
        }
        VStack(spacing: 6) {
          Text(battery.map { "\($0)%" } ?? "—")
            .font(.system(.largeTitle, design: .rounded).weight(.medium))
          Text(battery == nil ? "Battery unknown" : "Battery")
            .font(.caption).foregroundStyle(Color.secondaryInk)
            .multilineTextAlignment(.center).padding(.horizontal, 16)
        }
      }
      .frame(width: min(diameter, 260), height: min(diameter, 260))
    }
    .frame(maxWidth: .infinity).padding(12)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(battery.map { "Ring battery, \($0) percent" } ?? "Ring battery unknown")
  }
}

struct OnboardingView: View {
  @Environment(RingCoordinator.self) private var ring
  @Environment(\.dismiss) private var dismiss
  @State private var ready = false

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          PageHeading(
            title: "A fresh start\nfor your ring.",
            subtitle: "Connect without an Oura account or an existing key file.")
          RingIllustration()
          step(
            1, "Save what matters",
            "A factory reset erases measurements still on your ring. Sync them in your current app first, if you can."
          )
          step(
            2, "Reset your ring",
            "Use your charging dock to reset without the Oura app. Expand the instructions below before starting."
          )
          DisclosureGroup("Reset without the Oura app") {
            VStack(alignment: .leading, spacing: 14) {
              Text(
                "This erases unsynced measurements, Bluetooth bonds, and the existing authentication key."
              )
              .fontWeight(.medium)
              Text(
                "This charger procedure has now been confirmed on your Horizon Gen 3. LED colours guide each step."
              )
              Text(
                "1. Keep the dock powered. Remove the ring, then seat it and wait about two seconds."
              )
              Text("2. Hold the ring in place and flip the dock upside down. Wait for blue.")
              Text("3. Flip upright. Wait for red.")
              Text("4. Flip upside down again. Wait for purple.")
              Text(
                "5. Flip upright. Yellow indicates the reset has started. Wait a few minutes for blinking blue."
              )
              Text(
                "If the colours do not follow this sequence, stop; do not assume a reset occurred. Afterwards, pair with Oura Sync before onboarding in the Oura app again."
              )
              Link(
                "Read the reset research",
                destination: URL(
                  string: "https://github.com/Th0rgal/open_oura/blob/main/docs/factory-reset.md")!)
            }
            .font(.subheadline)
            .foregroundStyle(Color.secondaryInk)
            .padding(.top, 12)
          }
          step(
            3, "Make this its new home",
            "Keep your ring on its charger. Pair here after resetting, before setting it up in the Oura app again."
          )
          step(
            4, "Stay in sync",
            "After pairing, we’ll ask to send low-battery alerts and an occasional reminder to leave Oura Sync in the background. You can change these in My ring."
          )
          Toggle("My ring has been factory reset", isOn: $ready).font(.subheadline)
          if ready {
            Surface(prominent: true) {
              Text("Choose your ring").font(.headline)
              Text(
                "Keep your ring on its charger. If iOS asks to pair, approve the Bluetooth pairing request."
              ).font(.subheadline)
              Button("Find nearby rings") { ring.scan() }
                .buttonStyle(PrimaryButtonStyle()).disabled(ring.busy)
              if ring.transport?.isScanning == true {
                ProgressView("Looking for rings…")
                Button("Stop searching") { ring.transport?.stopScanning() }
              } else if ring.transport?.scanFinished == true, ring.transport?.nearby.isEmpty == true
              {
                Text(
                  "No ring found. Keep your ring on its powered charger near the phone, then search again."
                )
                .font(.subheadline)
              }
              ForEach(ring.transport?.nearby ?? []) { nearby in
                Button {
                  Task {
                    await ring.pair(id: nearby.id)
                    if ring.pairing?.peripheralID == nearby.id,
                      ring.pairing?.confirmed == true, ring.error == nil
                    {
                      await RingNotifications.shared.requestPermission()
                    }
                  }
                } label: {
                  VStack(alignment: .leading, spacing: 4) {
                    Text(nearby.name).fontWeight(.medium)
                    Text("Signal \(nearby.signal) dBm · \(nearby.id.uuidString.suffix(6))")
                      .font(.caption).foregroundStyle(Color.secondaryInk)
                  }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                    .contentShape(Rectangle())
                }.disabled(ring.busy)
              }
              if ring.busy {
                ProgressView(ring.message)
              } else {
                Text(ring.message).font(.subheadline)
              }
              if let error = ring.error { Text(error).font(.subheadline).foregroundStyle(.red) }
            }
          }
        }
        .padding(24)
      }
      .background(Color.paper).foregroundStyle(Color.ink)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }.disabled(ring.busy)
        }
      }
    }
    .tint(.forest)
    .task { ring.startBluetooth() }
    .onDisappear { ring.transport?.stopScanning() }
    .interactiveDismissDisabled(ring.busy)
  }

  private func step(_ number: Int, _ title: String, _ message: String) -> some View {
    HStack(alignment: .top, spacing: 14) {
      Text(number.formatted()).font(.caption.weight(.semibold))
        .frame(width: 28, height: 28).background(Color.softGreen, in: .circle)
      VStack(alignment: .leading, spacing: 6) {
        Text(title).font(.headline)
        Text(message).font(.subheadline).foregroundStyle(Color.secondaryInk)
      }
    }
  }
}
