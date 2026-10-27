import XCTest

@MainActor
final class OuraSyncUITests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  func testEmptyTabsAndOnboardingCanBeDismissed() {
    let app = XCUIApplication()
    app.launch()
    XCTAssertTrue(app.buttons["Set up my ring"].waitForExistence(timeout: 10))
    app.tabBars.buttons["Sleep"].tap()
    XCTAssertTrue(app.staticTexts["A night worth understanding."].exists)
    app.tabBars.buttons["Trends"].tap()
    XCTAssertTrue(app.staticTexts["Patterns take time."].exists)
    app.tabBars.buttons["My ring"].tap()
    reveal(app.buttons["Set up my ring"], in: app)
    app.buttons["Set up my ring"].tap()
    XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
    app.buttons["Done"].tap()
    XCTAssertTrue(app.tabBars.buttons["My ring"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["Done"].exists)
  }

  func testSimulatorSampleNavigationIsSeparateFromNormalLaunch() {
    let app = XCUIApplication()
    app.launchArguments = ["--preview"]
    app.launch()
    app.buttons["Explore your sleep"].tap()
    XCTAssertTrue(app.staticTexts["Sleep stages"].waitForExistence(timeout: 5))
    attachScreenshot("Sample sleep")
    app.tabBars.buttons["Trends"].tap()
    app.buttons["30 days"].tap()
    XCTAssertTrue(app.staticTexts["30-day average"].exists)
    app.terminate()
    app.launchArguments = []
    app.launch()
    XCTAssertTrue(app.buttons["Set up my ring"].exists)
    XCTAssertFalse(app.buttons["Explore your sleep"].exists)
    app.tabBars.buttons["My ring"].tap()
    XCTAssertFalse(app.switches["Explore with sample data"].exists)
    attachScreenshot("My ring connection and battery")
  }

  func testDecliningHealthPermissionKeepsAppUsable() throws {
    let app = XCUIApplication()
    app.resetAuthorizationStatus(for: .health)
    app.launch()
    app.tabBars.buttons["My ring"].tap()
    let connect = app.buttons["Connect Apple Health"]
    reveal(connect, in: app)
    connect.tap()
    let healthAccess = app.staticTexts["Health Access"]
    if !healthAccess.waitForExistence(timeout: 10) {
      attachScreenshot("Health permission unavailable")
      let unavailable = app.staticTexts.containing(
        NSPredicate(format: "label CONTAINS %@", "Apple Health is unavailable")
      ).firstMatch
      if unavailable.exists {
        throw XCTSkip("This simulator does not offer HealthKit authorization.")
      }
      XCTFail("Health authorization did not present its native sheet.")
      return
    }
    attachScreenshot("Native Health permission sheet")
    app.swipeUp()
    app.swipeUp()
    attachScreenshot("Health permission actions")
    let decline = app.buttons["UIA.Health.DoNotAllow.Button"]
    XCTAssertTrue(decline.waitForExistence(timeout: 5))
    decline.tap()
    let acknowledgement = app.alerts["Health Access"].buttons["OK"]
    XCTAssertTrue(acknowledgement.waitForExistence(timeout: 5))
    acknowledgement.tap()
    expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: healthAccess)
    waitForExpectations(timeout: 5)
    XCTAssertTrue(connect.waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["Pause Apple Health export"].exists)
    XCTAssertFalse(
      app.staticTexts.containing(
        NSPredicate(format: "label CONTAINS %@", "Ready to export")
      ).firstMatch.exists)
    attachScreenshot("Health permission declined")
    app.tabBars.buttons["Today"].tap()
    XCTAssertTrue(app.buttons["Set up my ring"].exists)
  }

  private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
    for _ in 0..<8 where !element.isHittable {
      app.swipeUp()
    }
    if !element.isHittable { attachScreenshot("Unreachable scroll target") }
    XCTAssertTrue(element.isHittable)
  }

  func testDecliningNotificationsKeepsPreferencesUsable() {
    let app = XCUIApplication()
    app.launch()
    app.tabBars.buttons["My ring"].tap()
    let settings = app.buttons["Ring notifications"]
    reveal(settings, in: app)
    settings.tap()
    let allow = app.buttons["Allow notifications"]
    if allow.exists {
      reveal(allow, in: app)
      allow.tap()
      let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
      let decline = springboard.alerts.buttons["Don’t Allow"]
      XCTAssertTrue(decline.waitForExistence(timeout: 5))
      attachScreenshot("Native notification permission")
      decline.tap()
    }
    let denied = app.staticTexts["Notifications are off in iPhone Settings."]
    XCTAssertTrue(denied.waitForExistence(timeout: 5))
    XCTAssertTrue(app.links["Open notification settings"].exists)
    let reminder = app.switches["Background-sync reminder"]
    reveal(reminder, in: app)
    let initialValue = reminder.value as? String
    reminder.tap()
    XCTAssertNotEqual(reminder.value as? String, initialValue)
    reminder.tap()
    XCTAssertEqual(reminder.value as? String, initialValue)
    attachScreenshot("Notifications declined, preferences available")
    app.tabBars.buttons["Today"].tap()
    XCTAssertTrue(app.buttons["Set up my ring"].exists)
  }

  func testRecordedChartsExplainMetricsAndAllowSelection() {
    let app = XCUIApplication()
    app.launchArguments = ["--recorded"]
    app.launch()
    XCTAssertTrue(app.staticTexts["Heart rate"].waitForExistence(timeout: 10))
    app.buttons["Today"].tap()
    let explore = app.buttons["Explore heart recordings"]
    reveal(explore, in: app)
    explore.tap()
    XCTAssertTrue(app.navigationBars["Heart recordings"].waitForExistence(timeout: 5))
    app.buttons["Understand these recordings"].tap()
    attachScreenshot("Heart recording explanation")
    let chart = app.descendants(matching: .any).matching(
      NSPredicate(format: "label == %@", "Recorded heart rate, without hourly averaging")
    ).firstMatch
    XCTAssertTrue(chart.exists)
    chart.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
      .press(
        forDuration: 0.5,
        thenDragTo: chart.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)))
    XCTAssertTrue(app.buttons["Show recorded range"].waitForExistence(timeout: 5))
    attachScreenshot("Recorded heart selection")
    app.buttons["Show recorded range"].tap()
    app.buttons["HRV"].tap()
    attachScreenshot("Recorded HRV detail")
    app.buttons["Done"].tap()
    attachScreenshot("Recorded metrics after heart dismissal")
    for title in [
      "Sleeping skin temperature", "Breathing rate", "Blood oxygen",
      "Activity intensity", "Movement",
    ] {
      let heading = app.staticTexts.matching(identifier: title).firstMatch
      for _ in 0..<20 where !heading.isHittable {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.75))
          .press(
            forDuration: 0.1,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.4)))
      }
      XCTAssertTrue(heading.isHittable, "Metric heading should be reachable: \(title)")
      attachScreenshot(title)
    }
    app.swipeUp()
    attachScreenshot("Activity intensity chart")
    reveal(app.staticTexts["Sleep recordings"], in: app)
    app.swipeUp()
    attachScreenshot("Recorded sleep stages")
  }

  func testRecordedAndSampleSleepAreReadable() {
    let app = XCUIApplication()
    app.launchArguments = ["--recorded"]
    app.launch()
    reveal(app.staticTexts["Sleep recordings"], in: app)
    app.swipeUp()
    XCTAssertTrue(app.staticTexts["RECORDED SLEEP"].exists)
    attachScreenshot("Recorded sleep design")
    app.terminate()
    app.launchArguments = ["--preview", "--sleep"]
    app.launch()
    XCTAssertTrue(app.staticTexts["Sleep stages"].waitForExistence(timeout: 10))
    attachScreenshot("Sample sleep design")
  }

  func testCompletedSleepExplainsFirmwareTimingAndHealthEligibility() {
    let app = XCUIApplication()
    app.launchArguments = [
      "--recorded", "--nightly-vitals-only", "--dense-sleep", "--anchored-sleep",
    ]
    app.launch()
    XCTAssertTrue(app.staticTexts["RECORDED SLEEP"].waitForExistence(timeout: 10))
    let explanation = app.staticTexts.matching(
      NSPredicate(
        format: "label == %@",
        "Stages reported by your ring, timed from its sleep summary. Complete recordings can sync to Apple Health when sleep access is allowed.")
    ).firstMatch
    reveal(explanation, in: app)
    XCTAssertTrue(explanation.exists)
    attachScreenshot("Completed firmware sleep timeline")
  }

  func testDenseSleepStagesRemainReadable() {
    let app = XCUIApplication()
    app.launchArguments = ["--recorded", "--nightly-vitals-only", "--dense-sleep"]
    app.launch()
    let chart = app.otherElements.containing(
      NSPredicate(format: "label == %@", "Ring sleep stages. Clock times are approximate.")
    ).firstMatch
    XCTAssertTrue(app.staticTexts["RECORDED SLEEP"].waitForExistence(timeout: 10))
    reveal(chart, in: app)
    attachScreenshot("Dense sleep stages with 91 transitions")
    XCTAssertTrue(app.buttons["Previous sleep recording"].isEnabled)
    app.buttons["Previous sleep recording"].tap()
    XCTAssertTrue(app.buttons["Next sleep recording"].isEnabled)
    app.buttons["Next sleep recording"].tap()
    XCTAssertFalse(app.buttons["Next sleep recording"].isEnabled)
  }

  func testSleepHistoryNavigatesDatesAndDisablesBoundaryButtons() throws {
    let app = XCUIApplication()
    app.launchArguments = ["--recorded"]
    app.launch()
    let previous = app.buttons["Previous sleep recording"]
    let next = app.buttons["Next sleep recording"]
    let chooser = app.buttons["Choose sleep recording"]
    reveal(previous, in: app)
    let latestDate = try XCTUnwrap(chooser.value as? String)
    XCTAssertTrue(previous.isEnabled)
    XCTAssertFalse(next.isEnabled)
    XCTAssertTrue(app.staticTexts["6h 4m"].exists)
    previous.tap()
    let middleDate = chooser.value as? String
    XCTAssertNotEqual(middleDate, latestDate)
    XCTAssertTrue(previous.isEnabled)
    XCTAssertTrue(next.isEnabled)
    XCTAssertTrue(app.staticTexts["5h 12m"].exists)
    previous.tap()
    XCTAssertNotEqual(chooser.value as? String, middleDate)
    XCTAssertFalse(previous.isEnabled)
    XCTAssertTrue(next.isEnabled)
    XCTAssertTrue(app.staticTexts["4h 46m"].exists)
    attachScreenshot("Oldest sleep recording")
    next.tap()
    XCTAssertEqual(chooser.value as? String, middleDate)
    chooser.tap()
    app.buttons[latestDate].tap()
    XCTAssertEqual(chooser.value as? String, latestDate)
    XCTAssertFalse(next.isEnabled)
    XCTAssertTrue(app.staticTexts["6h 4m"].exists)
    attachScreenshot("Latest sleep selected from date menu")
  }

  func testRecordedSleepSummaryShowsTimelineAndOpensHistory() throws {
    let app = XCUIApplication()
    app.launchArguments = ["--recorded", "--sleep-summary"]
    app.launch()
    XCTAssertTrue(app.staticTexts["LATEST RECORDED SLEEP"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["6h 4m"].firstMatch.isHittable)
    let timeline = app.descendants(matching: .any).matching(
      NSPredicate(format: "label == %@", "Ring sleep stages. Clock times are approximate.")
    ).firstMatch
    XCTAssertTrue(timeline.exists)
    attachScreenshot("Latest sleep summary with timeline")
    let explore = app.buttons["Explore your sleep"]
    reveal(explore, in: app)
    explore.tap()
    let chooser = app.buttons["Choose sleep recording"]
    XCTAssertTrue(chooser.waitForExistence(timeout: 5))
    XCTAssertTrue(chooser.isHittable)
    let selectedDate = try XCTUnwrap(chooser.value as? String)
    XCTAssertFalse(selectedDate.isEmpty)
    XCTAssertFalse(app.buttons["Next sleep recording"].isEnabled)
    attachScreenshot("Sleep summary opens latest history")
  }

  func testRingSettingsRemainUsableAtLargestTextSize() {
    let app = XCUIApplication()
    app.launchArguments = [
      "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
    ]
    app.launch()
    app.tabBars.buttons["My ring"].tap()
    reveal(app.staticTexts["Apple Health"], in: app)
    attachScreenshot("Largest text ring statuses")
    let health = app.buttons["Connect Apple Health"]
    reveal(health, in: app)
    XCTAssertTrue(health.isHittable)
    let notifications = app.buttons["Ring notifications"]
    reveal(notifications, in: app)
    notifications.tap()
    let battery = app.switches["Low-battery alerts"]
    reveal(battery, in: app)
    XCTAssertTrue(battery.isHittable)
    attachScreenshot("Largest text notification preferences")
    let reminder = app.switches["Background-sync reminder"]
    reveal(reminder, in: app)
    XCTAssertTrue(reminder.isHittable)
    attachScreenshot("Largest text notification explanation")
    app.terminate()
  }

  func testRingHeroShowsConnectionSyncAndUnknownBatteryStates() {
    let app = XCUIApplication()
    app.launchArguments = ["--ring-preview"]
    app.launch()
    XCTAssertTrue(app.staticTexts["Connected"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.descendants(matching: .any)["Ring battery, 82 percent"].exists)
    attachScreenshot("Connected ring battery")
    reveal(app.staticTexts["Syncing"], in: app)
    XCTAssertTrue(app.descendants(matching: .any)["Ring battery, 36 percent"].exists)
    attachScreenshot("Syncing ring battery")
    reveal(app.staticTexts["Disconnected"], in: app)
    XCTAssertTrue(app.descendants(matching: .any)["Ring battery unknown"].exists)
    attachScreenshot("Disconnected ring battery unknown")
  }

  func testDaytimeOnlyReadingsExplainMissingOvernightMetrics() {
    let app = XCUIApplication()
    app.launchArguments = ["--recorded", "--daytime-only"]
    app.launch()
    let overview = app.descendants(matching: .any).matching(
      NSPredicate(format: "label == %@", "Recorded heart rate, hourly averages and recorded ranges")
    ).firstMatch
    XCTAssertTrue(overview.waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Awaiting HRV recordings"].exists)
    attachScreenshot("Daytime heart overview")
    let explore = app.buttons["Explore heart recordings"]
    reveal(explore, in: app)
    explore.tap()
    let raw = app.descendants(matching: .any).matching(
      NSPredicate(format: "label == %@", "Recorded heart rate, without hourly averaging")
    ).firstMatch
    XCTAssertTrue(raw.waitForExistence(timeout: 5))
    attachScreenshot("Daytime raw heart detail")
    app.buttons["Done"].tap()
    reveal(app.staticTexts["Awaiting overnight readings"], in: app)
    XCTAssertTrue(
      app.staticTexts["HRV · Sleeping temperature · Blood oxygen · Breathing rate"].exists)
    XCTAssertFalse(app.staticTexts["Sleep recordings"].exists)
    attachScreenshot("Missing overnight readings explained")
  }

  func testNightlyVitalsShowAvailableAndMissingReadings() {
    let app = XCUIApplication()
    app.launchArguments = ["--recorded", "--nightly-vitals-only"]
    app.launch()
    reveal(app.staticTexts["During detected bedtime"], in: app)
    reveal(app.staticTexts["Average blood oxygen"], in: app)
    XCTAssertTrue(app.staticTexts["Average HRV"].exists)
    XCTAssertFalse(app.staticTexts["Awaiting readings"].firstMatch.exists)
    attachScreenshot("Nightly vitals from simulated recordings")
    app.terminate()
    app.launchArguments = ["--recorded", "--nightly-vitals-only", "--empty-nightly-vitals"]
    app.launch()
    reveal(app.staticTexts["During detected bedtime"], in: app)
    reveal(app.staticTexts["Average blood oxygen"], in: app)
    XCTAssertTrue(app.staticTexts["Awaiting readings"].firstMatch.exists)
    XCTAssertTrue(app.staticTexts["Awaiting consistent readings"].exists)
    attachScreenshot("Nightly vitals awaiting readings")
  }

  func testBedtimeOnlyAndMixedHistoryKeepLatestNightSelectable() throws {
    let app = XCUIApplication()
    for flag in ["--no-sleep-stages", "--latest-missing-stages"] {
      app.launchArguments = ["--recorded", "--nightly-vitals-only", flag]
      app.launch()
      let previous = app.buttons["Previous sleep recording"]
      let next = app.buttons["Next sleep recording"]
      let chooser = app.buttons["Choose sleep recording"]
      reveal(previous, in: app)
      let latest = try XCTUnwrap(chooser.value as? String)
      XCTAssertTrue(app.staticTexts["Recording 3 of 3"].exists)
      XCTAssertTrue(app.staticTexts["Awaiting sleep stages"].exists)
      XCTAssertFalse(next.isEnabled)
      attachScreenshot("Latest bedtime without stages \(flag)")
      previous.tap()
      XCTAssertNotEqual(chooser.value as? String, latest)
      if flag == "--latest-missing-stages" {
        XCTAssertTrue(app.staticTexts["RECORDED SLEEP"].exists)
        XCTAssertTrue(app.staticTexts["5h 12m"].exists)
        XCTAssertFalse(app.staticTexts["Awaiting sleep stages"].exists)
      } else {
        XCTAssertTrue(app.staticTexts["Awaiting sleep stages"].exists)
      }
      previous.tap()
      XCTAssertFalse(previous.isEnabled)
      chooser.tap()
      app.buttons[latest].tap()
      XCTAssertFalse(next.isEnabled)
      XCTAssertTrue(app.staticTexts["Awaiting sleep stages"].exists)
      reveal(app.staticTexts["During detected bedtime"], in: app)
      attachScreenshot("Bedtime-only nightly vitals \(flag)")
      app.terminate()
    }
  }

  func testLiveHeartRateWaitsForValidReadingAndStops() {
    let app = XCUIApplication()
    app.launchArguments = ["--live-heart-preview"]
    app.launch()
    app.buttons["Open live measurement"].tap()
    func textContaining(_ text: String) -> XCUIElement {
      app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }
    XCTAssertTrue(textContaining("Ready for a live reading").waitForExistence(timeout: 10))
    attachScreenshot("Live heart rate ready")
    reveal(app.buttons["Start measurement"], in: app)
    app.buttons["Start measurement"].tap()
    XCTAssertTrue(textContaining("Waiting for a reading…").waitForExistence(timeout: 5))
    XCTAssertTrue(textContaining("—").exists)
    attachScreenshot("Live heart rate waiting")
    app.buttons["Deliver simulated reading"].tap()
    XCTAssertTrue(
      app.staticTexts.containing(
        NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "72", "bpm")
      ).firstMatch.waitForExistence(timeout: 5))
    attachScreenshot("Valid live heart reading")
    reveal(app.buttons["Stop measurement"], in: app)
    app.buttons["Stop measurement"].tap()
    XCTAssertTrue(textContaining("Live reading finished").waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["Start measurement"].exists)
    XCTAssertFalse(app.buttons["Stop measurement"].exists)
    attachScreenshot("Live heart measurement ended")
    app.buttons["Start measurement"].tap()
    XCTAssertTrue(
      app.staticTexts.containing(
        NSPredicate(format: "label CONTAINS %@", "Waiting for a reading…")
      ).firstMatch.waitForExistence(timeout: 5))
    app.buttons["Done"].tap()
    XCTAssertTrue(app.staticTexts["Preview session stopped"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["Stop measurement"].exists)
  }

  func testLiveHeartSheetRemainsUsableAtLargestTextSize() {
    let app = XCUIApplication()
    app.launchArguments = [
      "--live-heart-preview", "-UIPreferredContentSizeCategoryName",
      "UICTContentSizeCategoryAccessibilityXXXL",
    ]
    app.launch()
    app.buttons["Open live measurement"].tap()
    reveal(app.buttons["Start measurement"], in: app)
    attachScreenshot("Largest text live sheet ready")
    app.buttons["Start measurement"].tap()
    reveal(app.buttons["Stop measurement"], in: app)
    XCTAssertTrue(app.buttons["Stop measurement"].isHittable)
    attachScreenshot("Largest text live sheet recording")
    app.buttons["Stop measurement"].tap()
    XCTAssertTrue(app.buttons["Start measurement"].waitForExistence(timeout: 5))
    app.buttons["Start measurement"].tap()
    XCTAssertTrue(
      app.staticTexts.containing(
        NSPredicate(format: "label CONTAINS %@", "Waiting for a reading…")
      ).firstMatch.waitForExistence(timeout: 5))
    app.buttons["Done"].tap()
    XCTAssertTrue(app.staticTexts["Preview session stopped"].waitForExistence(timeout: 5))
    app.terminate()
  }

  func testNightlyTrendsSwitchMetricsSelectNightAndKeepMissingValuesEmpty() {
    let app = XCUIApplication()
    app.launchArguments = ["--recorded", "--nightly-trends"]
    app.launch()
    let picker = app.buttons["nightlyMetricPicker"]
    XCTAssertTrue(picker.waitForExistence(timeout: 10))
    let chart = app.descendants(matching: .any).matching(
      NSPredicate(format: "label == %@", "Nightly heart rate chart")
    ).firstMatch
    XCTAssertTrue(chart.exists)
    attachScreenshot("Nightly heart overview")
    chart.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5))
      .press(
        forDuration: 0.5,
        thenDragTo: chart.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
    XCTAssertTrue(
      app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Selected")).firstMatch
        .waitForExistence(timeout: 5))
    attachScreenshot("Selected nightly heart trend")
    picker.tap()
    app.buttons["Heart rate variability"].tap()
    attachScreenshot("Nightly HRV trend")
    picker.tap()
    app.buttons["Skin temperature"].tap()
    XCTAssertTrue(
      app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "34.00")).firstMatch
        .exists)
    app.buttons["30 days"].tap()
    attachScreenshot("Thirty-day nightly temperature")
    app.buttons["7 days"].tap()
    app.terminate()
    app.launchArguments = ["--recorded", "--nightly-trends", "--empty-nightly-vitals"]
    app.launch()
    XCTAssertTrue(app.staticTexts["Awaiting heart rate recordings"].waitForExistence(timeout: 10))
    XCTAssertFalse(chart.exists)
    attachScreenshot("Nightly trend awaiting readings")
  }

  #if NOTIFICATION_DELIVERY_QA
    // Opt-in integration check: run on a fresh simulator to verify the first native Allow prompt.
    func testFreshSimulatorDeliversBatteryAlertAndRearmsAfterCharging() throws {
      let app = XCUIApplication()
      app.launchArguments = ["--notifications-preview"]
      app.launch()
      app.buttons["Request notification permission"].tap()
      let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
      let allow = springboard.alerts.buttons["Allow"]
      XCTAssertTrue(allow.waitForExistence(timeout: 10))
      attachScreenshot("Native notification permission")
      allow.tap()
      XCTAssertTrue(app.staticTexts["Notifications allowed"].waitForExistence(timeout: 5))
      func refreshUntilCount(_ count: Int) {
        for _ in 0..<10 {
          app.buttons["Refresh delivered alerts"].tap()
          if app.staticTexts["Delivered: \(count)"].exists { return }
        }
        XCTFail("Expected \(count) delivered low-battery alerts")
      }
      app.buttons["Report 20% battery"].tap()
      refreshUntilCount(1)
      XCTAssertTrue(app.staticTexts["Time to charge your ring"].exists)
      XCTAssertTrue(
        app.staticTexts[
          "Your ring reported 20% battery. Place it on its charger to keep recording."
        ]
        .exists)
      let firstDelivery = app.staticTexts["deliveredTimestamp"].label
      attachScreenshot("Delivered native low battery alert")
      app.buttons["Report 19% battery"].tap()
      refreshUntilCount(1)
      XCTAssertEqual(app.staticTexts["deliveredTimestamp"].label, firstDelivery)
      XCTAssertFalse(
        app.staticTexts[
          "Your ring reported 19% battery. Place it on its charger to keep recording."
        ]
        .exists)
      app.buttons["Report 30% battery"].tap()
      refreshUntilCount(0)
      app.buttons["Report 20% battery"].tap()
      refreshUntilCount(1)
      XCTAssertNotEqual(app.staticTexts["deliveredTimestamp"].label, firstDelivery)
      attachScreenshot("Battery alert delivered after recharge")
    }

    // Run independently on a fresh simulator; authorization must present natively.
    func testFreshSimulatorBackgroundReminderCancelsAndDeliversOncePerDay() {
      let app = XCUIApplication()
      app.launchArguments = ["--notifications-preview"]
      app.launch()
      app.buttons["Request notification permission"].tap()
      let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
      XCTAssertTrue(allow.waitForExistence(timeout: 10))
      allow.tap()
      XCTAssertTrue(app.staticTexts["Notifications allowed"].waitForExistence(timeout: 5))
      XCUIDevice.shared.press(.home)
      Thread.sleep(forTimeInterval: 2)
      app.activate()
      app.buttons["Refresh delivered alerts"].tap()
      attachScreenshot("Reminder quick-return lifecycle")
      XCTAssertTrue(app.staticTexts["Pending reminders: 0"].exists)
      Thread.sleep(forTimeInterval: 12)
      app.buttons["Refresh delivered alerts"].tap()
      XCTAssertTrue(app.staticTexts["Delivered reminders: 0"].exists)
      attachScreenshot("Quick return cancels scheduled reminder")
      XCUIDevice.shared.press(.home)
      Thread.sleep(forTimeInterval: 15)
      app.activate()
      app.buttons["Refresh delivered alerts"].tap()
      XCTAssertTrue(app.staticTexts["Delivered reminders: 1"].exists)
      XCTAssertTrue(app.staticTexts["Keep Oura Sync in the background"].exists)
      let timestamp = app.staticTexts["reminderTimestamp"].label
      attachScreenshot("Real background reminder delivered")
      XCUIDevice.shared.press(.home)
      Thread.sleep(forTimeInterval: 15)
      app.activate()
      app.buttons["Refresh delivered alerts"].tap()
      XCTAssertTrue(app.staticTexts["Delivered reminders: 1"].exists)
      XCTAssertTrue(app.staticTexts["Pending reminders: 0"].exists)
      XCTAssertEqual(app.staticTexts["reminderTimestamp"].label, timestamp)
      attachScreenshot("Background reminder not repeated within a day")
    }

  #endif

  private func attachScreenshot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
