#if DEBUG && targetEnvironment(simulator)
  import OuraProtocol
  import SwiftUI

  struct RecordedMetricsPreview: View {
    @State private var days = ProcessInfo.processInfo.arguments.contains("--daytime-only") ? 1 : 7
    private let fixtures = RecordedMetricsFixtures()

    private var nightlyTrends: Bool {
      ProcessInfo.processInfo.arguments.contains("--nightly-trends")
    }
    private var daytimeOnly: Bool { ProcessInfo.processInfo.arguments.contains("--daytime-only") }
    private var measurements: [OuraProtocol.Measurement] {
      daytimeOnly
        ? fixtures.measurements.filter {
          [.heartRate, .activityMET, .motionSeconds].contains($0.kind)
        } : fixtures.measurements
    }

    var body: some View {
      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 24) {
            Text("SAMPLE DATA").font(.caption.weight(.semibold)).tracking(2)
            PageHeading(
              title: "Your recorded rhythm.", subtitle: "Seven days of simulated ring recordings.")
            if !daytimeOnly, ProcessInfo.processInfo.arguments.contains("--sleep-summary"),
              let latest = fixtures.sleep.last
            {
              RecordedSleepSummary(period: latest) {
                proxy.scrollTo("sleep-history", anchor: .top)
              }
            }
            Picker("Time range", selection: $days) {
              Text("Today").tag(1)
              Text("7 days").tag(7)
              Text("30 days").tag(30)
            }.pickerStyle(.segmented)
            if nightlyTrends {
              NightlyTrendsView(nights: fixtures.nightlyVitals, days: days)
            } else if !ProcessInfo.processInfo.arguments.contains("--nightly-vitals-only") {
              RecordedVitalsView(measurements: measurements, days: days)
            }
            if !nightlyTrends, !daytimeOnly,
              !fixtures.sleep.isEmpty || !fixtures.nightlyVitals.isEmpty
            {
              Text("Sleep recordings").font(.title2.weight(.medium))
              RecordedSleepHistoryView(
                periods: fixtures.sleep, measurements: fixtures.measurements,
                nightlyVitals: fixtures.nightlyVitals
              )
              .id("sleep-history")
            }
          }
          .padding(24)
        }
        .background(Color.paper)
        .foregroundStyle(Color.ink)
      }
    }
  }

  private struct RecordedMetricsFixtures {
    let measurements: [OuraProtocol.Measurement]
    let sleep: [SleepStagePeriod]
    let nightlyVitals: [NightlyVitals]

    init() {
      let now = Date(timeIntervalSince1970: floor(Date.now.timeIntervalSince1970 / 3600) * 3600)
      let counter: UInt32 = 10_000_000
      let session = UUID(uuidString: "A1000000-0000-0000-0000-000000000001")!
      var events = [Self.event(0x42, counter, Self.bytes(UInt32(now.timeIntervalSince1970)))]
      for day in 0..<7 {
        for hour in stride(from: 0, to: 24, by: 3) {
          let timestamp = counter - UInt32((day * 24 + hour) * 36_000)
          let variation = (day * 3 + hour) % 9
          events.append(
            Self.event(0x5d, timestamp, [UInt8(53 + variation), UInt8(39 + variation * 2)]))
          let temperature = UInt16(3310 + variation * 8)
          events.append(
            Self.event(
              0x75, timestamp, [UInt8(truncatingIfNeeded: temperature), UInt8(temperature >> 8)]))
          events.append(
            Self.event(0x6a, timestamp, [0, 0, 0, 0, UInt8(112 + variation), 0, 60, 1, 0, 0]))
          events.append(
            Self.event(0x50, timestamp, [0, UInt8(11 + variation * 3), UInt8(14 + variation * 2)]))
          // Exercise the same complete-minute path as recorded ring history.
          for second in 0...60 {
            let oxygenTime = timestamp - 600 + UInt32(second * 10)
            events.append(Self.event(0x47, oxygenTime, [2]))
            let reading = UInt8(96 + variation % 4)
            events.append(
              Self.event(
                0x6f, oxygenTime,
                second == 60 ? [0, reading, 255] : [0, reading]))
          }
          events.append(Self.event(0x47, timestamp, [UInt8(variation * 3), 0, 0, 0]))
        }
      }
      // Distinct night lengths make history navigation observable in UI tests.
      for day in (0..<3).reversed() {
        let sleepEnd = counter - 3_600 - UInt32(day * 864_000)
        let denseSleep = day == 0 && ProcessInfo.processInfo.arguments.contains("--dense-sleep")
        let pageCount = denseSleep ? 20 : 16 - day * 2
        let anchored = day == 0 && ProcessInfo.processInfo.arguments.contains("--anchored-sleep")
        let sleepMinutes = pageCount * 26 - (anchored ? 16 : 0)
        let denseBytes = denseSleep ? Self.denseSleepBytes() : []
        events.append(
          Self.event(
            0x76, sleepEnd,
            Self.bytes(sleepEnd - UInt32(sleepMinutes * 600)) + Self.bytes(sleepEnd)))
        if ProcessInfo.processInfo.arguments.contains("--no-sleep-stages")
          || (day == 0 && ProcessInfo.processInfo.arguments.contains("--latest-missing-stages"))
        {
          continue
        }
        if anchored {
          let startOffset = UInt16(sleepMinutes)
          events.append(
            Self.event(
              0x49, sleepEnd,
              [UInt8(truncatingIfNeeded: startOffset), UInt8(startOffset >> 8), 0, 0]))
        }
        for page in 0..<pageCount {
          let packed: UInt8 = [0x55, 0x00, 0x55, 0xaa, 0x55, 0xff, 0x55, 0xaa][page % 8]
          let body =
            denseSleep
            ? Array(denseBytes[(page * 13)..<((page + 1) * 13)])
            : Array(repeating: packed, count: 13)
          events.append(
            Self.event(0x5a, sleepEnd + (anchored ? UInt32(page + 1) : 0), [UInt8(page)] + body))
        }
        if anchored {
          events.append(
            Self.event(0x4c, sleepEnd + UInt32(pageCount + 1), Array(repeating: 0, count: 14)))
        }
      }
      if ProcessInfo.processInfo.arguments.contains("--nightly-trends") {
        for page in 0..<6 {
          let end = counter - 7_200 - UInt32((5 - page) * 20 * 300)
          events.append(
            Self.event(0x75, end, (0..<20).flatMap { _ in [UInt8(0x48), UInt8(0x0d)] }))
        }
      }
      measurements = Measurements(events: events, session: session, now: now).samples
      sleep = SleepStages(events: events, session: session, now: now).periods
      let nightlyMeasurements =
        ProcessInfo.processInfo.arguments.contains("--empty-nightly-vitals")
        ? measurements.filter { $0.kind == .inBed } : measurements
      nightlyVitals = NightlyVitals.calculate(measurements: nightlyMeasurements, session: session)
    }

    private static func denseSleepBytes() -> [UInt8] {
      // 1,040 half-minute epochs: 8h 40m, 91 transitions, including 14 short runs.
      var epochs: [UInt8] = []
      var extraEpochs = 12
      for run in 0..<92 {
        let short = run.isMultiple(of: 7)
        let extra = !short && extraEpochs > 0 ? 1 : 0
        extraEpochs -= extra
        let stage: UInt8 = [1, 0, 1, 2, 1, 3][run % 6]
        epochs += Array(repeating: stage, count: short ? 1 : 13 + extra)
      }
      return stride(from: 0, to: epochs.count, by: 4).map { index in
        (epochs[index] << 6) | (epochs[index + 1] << 4)
          | (epochs[index + 2] << 2) | epochs[index + 3]
      }
    }

    private static func bytes(_ value: UInt32) -> [UInt8] {
      (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }

    private static func event(_ tag: UInt8, _ timestamp: UInt32, _ body: [UInt8]) -> RingEvent {
      do {
        return try RingEvent(packet: Packet(tag: tag, payload: bytes(timestamp) + body))
      } catch {
        preconditionFailure("Invalid simulator fixture: \(error)")
      }
    }
  }
#endif

#if DEBUG && targetEnvironment(simulator)
  struct LiveHeartRatePreview: View {
    @State private var session = LiveHeartRateSession()
    @State private var presented = false

    var body: some View {
      VStack(spacing: 24) {
        Button("Open live measurement") { presented = true }
        Text(session.running ? "Preview session running" : "Preview session stopped")
      }
      .sheet(isPresented: $presented) {
        VStack(spacing: 0) {
          LiveHeartRateView(
            session: session, syncing: false,
            start: { session.start(prepare: {}, enable: {}, restore: {}, didFinish: {}) },
            stop: { session.stop() }
          )
          Button("Deliver simulated reading") {
            let packet = Packet(tag: 0x2f, payload: [0x28, 2, 0, 0, 0, 0, 0x41, 0x13])
            if let reading = LiveHeartRateReading(packet: packet) { session.receive(reading) }
          }
          .font(.system(size: 14)).frame(minHeight: 44).disabled(!session.running)
        }
      }
    }
  }
#endif
