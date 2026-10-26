import OuraProtocol
import XCTest

@testable import OuraSync

@MainActor
final class LiveHeartRateSessionTests: XCTestCase {
  func testStoppingDuringEnableRestoresBeforeReleasingOwnership() async throws {
    let session = LiveHeartRateSession()
    let enabling = expectation(description: "enable started")
    let restoring = expectation(description: "restore started")
    let finished = expectation(description: "finished")
    var releaseEnable: CheckedContinuation<Void, Never>?
    var releaseRestore: CheckedContinuation<Void, Never>?
    session.start(
      prepare: {},
      enable: {
        await withCheckedContinuation { continuation in
          releaseEnable = continuation
          enabling.fulfill()
        }
      },
      restore: {
        XCTAssertFalse(Task.isCancelled)
        await withCheckedContinuation { continuation in
          releaseRestore = continuation
          restoring.fulfill()
        }
      }, didFinish: { finished.fulfill() })
    await fulfillment(of: [enabling], timeout: 2)
    session.stop()
    XCTAssertTrue(session.stopping)
    releaseEnable?.resume()
    await fulfillment(of: [restoring], timeout: 2)
    XCTAssertTrue(session.running)
    XCTAssertTrue(session.stopping)
    XCTAssertFalse(session.start(prepare: {}, enable: {}, restore: {}, didFinish: {}))
    session.stop()
    releaseRestore?.resume()
    await fulfillment(of: [finished], timeout: 2)
    XCTAssertFalse(session.running)
    XCTAssertFalse(session.stopping)
    XCTAssertNil(session.error)
  }

  func testTimedSessionWithoutReadingsStillRestores() async {
    let session = LiveHeartRateSession(duration: .milliseconds(1))
    let finished = expectation(description: "finished")
    var restored = false
    session.start(
      prepare: {}, enable: {}, restore: { restored = true }, didFinish: { finished.fulfill() })
    await fulfillment(of: [finished], timeout: 2)
    XCTAssertTrue(restored)
    XCTAssertNil(session.latest)
    XCTAssertNil(session.receivedAt)
    XCTAssertNil(session.error)
    XCTAssertFalse(session.running)
  }

  func testRestoreFailureRemainsVisibleAfterSessionEnds() async {
    let session = LiveHeartRateSession(duration: .zero)
    let finished = expectation(description: "finished")
    session.start(
      prepare: {}, enable: {},
      restore: {
        throw RingClient.Failure("Ring disconnected")
      }, didFinish: { finished.fulfill() })
    await fulfillment(of: [finished], timeout: 2)
    XCTAssertTrue(session.error?.contains("Ring disconnected") == true)
    XCTAssertFalse(session.running)
  }

  func testPreparationFailureNeverChangesFeatureMode() async {
    let session = LiveHeartRateSession(duration: .zero)
    let finished = expectation(description: "finished")
    session.start(
      prepare: { throw RingClient.Failure("Authentication failed") },
      enable: {
        XCTFail("Must not enable after failed authentication")
      }, restore: { XCTFail("No mode change was attempted") }, didFinish: { finished.fulfill() })
    await fulfillment(of: [finished], timeout: 2)
    XCTAssertEqual(session.error, "Authentication failed")
  }

  func testReadingsAreAcceptedOnlyWhileMeasuringAndPreservedAfterStop() async throws {
    let session = LiveHeartRateSession()
    let enabled = expectation(description: "enabled")
    let finished = expectation(description: "finished")
    let reading = try XCTUnwrap(
      LiveHeartRateReading(
        packet:
          Packet(tag: 0x2f, payload: [0x28, 2, 0, 2, 0, 0, 0x59, 0x13])))
    session.receive(reading)
    XCTAssertNil(session.latest)
    session.start(
      prepare: {},
      enable: {
        session.receive(reading)
        XCTAssertNil(session.latest)
        enabled.fulfill()
      }, restore: {}, didFinish: { finished.fulfill() })
    await fulfillment(of: [enabled], timeout: 2)
    let date = Date(timeIntervalSince1970: 1_790_000_000)
    session.receive(reading, at: date)
    XCTAssertEqual(session.latest, reading)
    XCTAssertEqual(session.receivedAt, date)
    session.stop()
    session.receive(reading, at: date.addingTimeInterval(60))
    await fulfillment(of: [finished], timeout: 2)
    XCTAssertEqual(session.receivedAt, date)
    XCTAssertNil(session.error)
  }
}
