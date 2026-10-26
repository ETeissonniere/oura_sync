import SwiftUI

struct RootView: View {
  enum Tab: Hashable { case today, sleep, trends, ring }
  @State private var selectedTab: Tab = .today
  private let preview: Bool
  @State private var ring = RingCoordinator.shared
  @Environment(\.scenePhase) private var scenePhase

  init() {
    #if DEBUG && targetEnvironment(simulator)
      let arguments = ProcessInfo.processInfo.arguments
      preview = arguments.contains("--preview")
      let tabs: [(String, Tab)] = [("--sleep", .sleep), ("--trends", .trends), ("--ring", .ring)]
      _selectedTab = State(
        initialValue: tabs.first(where: { arguments.contains($0.0) })?.1 ?? .today)
    #else
      preview = false
    #endif
  }

  var body: some View {
    #if DEBUG && targetEnvironment(simulator)
      if ProcessInfo.processInfo.arguments.contains("--notifications-preview") {
        NotificationDeliveryPreview()
      } else if ProcessInfo.processInfo.arguments.contains("--live-heart-preview") {
        LiveHeartRatePreview()
      } else if ProcessInfo.processInfo.arguments.contains("--ring-preview") {
        RingStatusPreview()
      } else if ProcessInfo.processInfo.arguments.contains("--recorded") {
        RecordedMetricsPreview()
      } else {
        mainContent
      }
    #else
      mainContent
    #endif
  }

  private var mainContent: some View {
    TabView(selection: $selectedTab) {
      page {
        TodayView(
          preview: preview, showSleep: { selectedTab = .sleep }, showRing: { selectedTab = .ring })
      }
      .tabItem { Label("Today", systemImage: "sun.max") }.tag(Tab.today)
      page { SleepView(preview: preview) }
        .tabItem { Label("Sleep", systemImage: "moon") }.tag(Tab.sleep)
      page { TrendsView(preview: preview) }
        .tabItem { Label("Trends", systemImage: "chart.xyaxis.line") }.tag(Tab.trends)
      page(syncOnRefresh: true) { RingView() }
        .tabItem { Label("My ring", systemImage: "circle") }.tag(Tab.ring)
    }
    .tint(.forest)
    .environment(ring)
    .task {
      if scenePhase == .active {
        await RingNotifications.shared.becameActive(ringID: ring.pairing?.peripheralID)
      }
      await ring.refreshMeasurements()
    }
    .onChange(of: scenePhase) { _, phase in
      if phase != .active { ring.stopLiveHeartRate() }
      if phase == .active {
        Task { await ring.retryHealthExport() }
        Task {
          await RingNotifications.shared.becameActive(ringID: ring.pairing?.peripheralID)
          if ring.pairing?.confirmed == true { await ring.sync() }
        }
      } else if phase == .background {
        BackgroundSync.schedule()
        if let pairing = ring.pairing, pairing.confirmed {
          Task { await RingNotifications.shared.enteredBackground(ringID: pairing.peripheralID) }
        }
      }
    }
  }

  private func page<Content: View>(
    syncOnRefresh: Bool = false, @ViewBuilder content: () -> Content
  ) -> some View {
    NavigationStack {
      let scroll = ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          HStack {
            Text("OURA SYNC").font(.caption.weight(.semibold)).tracking(2)
            Spacer()
            if preview {
              Text("SAMPLE DATA").font(.caption2).tracking(0.8).foregroundStyle(Color.secondaryInk)
            }
          }
          content()
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 30)
      }
      .background(Color.paper)
      .foregroundStyle(Color.ink)
      .toolbar(.hidden, for: .navigationBar)
      if syncOnRefresh {
        scroll.refreshable {
          if ring.pairing?.confirmed == true { await ring.sync() }
        }
      } else {
        scroll
      }
    }
  }
}

struct EmptyMeasurements: View {
  let title: String
  let message: String
  var body: some View {
    Surface(prominent: true) {
      Image(systemName: "waveform.path").font(.title).foregroundStyle(Color.forest)
        .accessibilityHidden(true)
      Text(title).font(.title2)
      Text(message).font(.subheadline).foregroundStyle(Color.secondaryInk)
    }
  }
}
