import Foundation
import Testing

@testable import OuraProtocol

private let sleepReference = Date(timeIntervalSince1970: 1_790_000_000)
private func sleepBytes(_ value: UInt32) -> [UInt8] {
  (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
}
private func sleepEvent(_ tag: UInt8, _ timestamp: UInt32, _ body: [UInt8]) throws -> RingEvent {
  try RingEvent(packet: Packet(tag: tag, payload: sleepBytes(timestamp) + body))
}
private func sleepAnchor(at timestamp: UInt32 = 100_000, unix: UInt32 = 1_790_000_000) throws
  -> RingEvent
{
  try sleepEvent(0x42, timestamp, sleepBytes(unix))
}
private func sleepPage(
  _ number: UInt8, at timestamp: UInt32 = 100_000, packed: UInt8 = 0b00_01_10_11
) throws -> RingEvent {
  try sleepEvent(0x5a, timestamp, [number] + Array(repeating: packed, count: 13))
}

@Test func horizonPagesDecodeMSBFirstThirtySecondStages() throws {
  let decoded = SleepStages(
    events: try [sleepAnchor(), sleepPage(0), sleepPage(1)], session: UUID(), now: sleepReference)
  let period = try #require(decoded.periods.first)
  #expect(period.epochs.count == 104)
  #expect(period.epochs.prefix(4).map(\.stage) == [.deep, .light, .rem, .awake])
  #expect(period.end == sleepReference)
  #expect(period.start == sleepReference.addingTimeInterval(-52 * 60))
  #expect(period.epochs.allSatisfy { $0.end.timeIntervalSince($0.start) == 30 })
  #expect(period.timing == .estimatedFromAnalysisCompletion)
  #expect(period.recordedBedtime == nil)
}

@Test(arguments: [[UInt8](arrayLiteral: 0, 2), [1, 2], [0, 1, 3]])
func missingSleepPagesAreNotInvented(pageNumbers: [UInt8]) throws {
  let events = try [sleepAnchor()] + pageNumbers.map { try sleepPage($0) }
  let decoded = SleepStages(events: events, session: UUID(), now: sleepReference)
  #expect(decoded.periods.isEmpty)
  #expect(decoded.rejectedRuns == 1)
}

@Test func malformedSleepPageDoesNotBecomeAwakeOrDeepTime() throws {
  let events = try [sleepAnchor(), sleepPage(0), sleepEvent(0x5a, 100_000, [1, 0])]
  let decoded = SleepStages(events: events, session: UUID(), now: sleepReference)
  #expect(decoded.periods.isEmpty)
  #expect(decoded.rejectedRuns == 1)
}

@Test func exactPageReplayDoesNotDuplicateSleep() throws {
  let page = try sleepPage(0)
  let session = UUID()
  let first = SleepStages(events: try [sleepAnchor(), page], session: session, now: sleepReference)
  let replayed = SleepStages(
    events: try [sleepAnchor(), page, page], session: session, now: sleepReference)
  #expect(first.periods == replayed.periods)
}

@Test func newPageZeroStartsAnIndependentSleepRun() throws {
  let events = try [sleepAnchor(), sleepPage(0, at: 50_000), sleepPage(0)]
  let decoded = SleepStages(events: events, session: UUID(), now: sleepReference)
  #expect(decoded.periods.count == 2)
  #expect(Set(decoded.periods.map(\.id)).count == 2)
}

@Test func sleepPagesNeedValidClockAndNonnegativeCounters() throws {
  let session = UUID()
  #expect(
    try SleepStages(events: [sleepPage(0)], session: session, now: sleepReference).undatedRuns == 1)
  let futureAnchor = try sleepAnchor(unix: 1_790_000_001)
  #expect(
    try SleepStages(events: [futureAnchor, sleepPage(0)], session: session, now: sleepReference)
      .periods.isEmpty)
  let futurePage = try sleepPage(0, at: 100_010)
  #expect(
    try SleepStages(events: [sleepAnchor(), futurePage], session: session, now: sleepReference)
      .undatedRuns == 1)
  #expect(
    try SleepStages(
      events: [sleepAnchor(), sleepPage(0, at: 100)], session: session, now: sleepReference
    ).rejectedRuns == 1)
}

@Test func clockCorrectionDoesNotStretchSleepEpochs() throws {
  let events = try [sleepAnchor(at: 80_000), sleepAnchor(unix: 1_789_999_000), sleepPage(0)]
  let decoded = SleepStages(events: events, session: UUID(), now: sleepReference)
  let period = try #require(decoded.periods.first)
  #expect(period.end == sleepReference.addingTimeInterval(-1_000))
  #expect(period.end.timeIntervalSince(period.start) == 26 * 60)
}

@Test func bedtimeDoesNotOverrideInferredStagePlacement() throws {
  let events = try [
    sleepAnchor(), sleepPage(0), sleepEvent(0x76, 100_000, sleepBytes(80_000) + sleepBytes(99_000)),
  ]
  let period = try #require(
    SleepStages(events: events, session: UUID(), now: sleepReference).periods.first)
  #expect(period.end == sleepReference)
  #expect(period.start == sleepReference.addingTimeInterval(-26 * 60))
  #expect(period.recordedBedtime?.end == sleepReference.addingTimeInterval(-100))
  #expect(period.recordedBedtime?.start == sleepReference.addingTimeInterval(-2_000))
}

@Test func widelySeparatedPagesDoNotJoinDifferentAnalyses() throws {
  let events = try [sleepAnchor(), sleepPage(0, at: 60_000), sleepPage(1)]
  let decoded = SleepStages(events: events, session: UUID(), now: sleepReference)
  #expect(decoded.periods.isEmpty)
  #expect(decoded.rejectedRuns == 1)
}

@Test(arguments: [UInt32(99_000), UInt32(99_001)])
func clockCorrectionAfterBedtimePreservesNightlySummaryAssociation(bedtimeEnd: UInt32) throws {
  let session = UUID()
  let events = try [
    sleepAnchor(at: 80_000, unix: 1_789_998_000),
    sleepEvent(0x76, bedtimeEnd, sleepBytes(80_000) + sleepBytes(bedtimeEnd)),
    sleepAnchor(at: 99_500, unix: 1_789_999_900),
    sleepPage(0),
  ]
  let period = try #require(
    SleepStages(events: events, session: session, now: sleepReference).periods.first)
  let readings = Measurements(events: events, session: session, now: sleepReference).samples
  let summary = try #require(
    NightlyVitals.calculate(measurements: readings, session: session).first)
  #expect(period.session == summary.session)
  #expect(period.recordedBedtime?.start == summary.start)
  #expect(period.recordedBedtime?.end == summary.end)
  #expect(
    summary.end == Date(timeIntervalSince1970: 1_789_998_000 + Double(bedtimeEnd - 80_000) / 10))
  #expect(period.end == sleepReference.addingTimeInterval(-50))
}
