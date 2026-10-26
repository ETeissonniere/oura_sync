import Foundation
import Testing

@testable import OuraProtocol

private let referenceTime = Date(timeIntervalSince1970: 1_790_000_000)
private func event(_ tag: UInt8, at timestamp: UInt32, body: [UInt8]) throws -> RingEvent {
  try RingEvent(packet: Packet(tag: tag, payload: littleEndian(timestamp) + body))
}
private func littleEndian(_ value: UInt32) -> [UInt8] {
  (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
}

private func greenBeat(ibi: UInt16, quality: UInt8) -> [UInt8] {
  [UInt8(ibi >> 3), UInt8(ibi & 7) | (quality << 3)]
}

@Test(arguments: [
  ([UInt8(0), 0, 0, 0], 0.0),
  ([UInt8(0b1111_1111), 255, 128, 127, 63], 31.0),
  ([UInt8(0b1010_0111), 1, 2, 3, 0, 63], 7.0),
])
func movementSummaryPreservesRecordedSecondsWithoutInventingWindow(body: [UInt8], seconds: Double)
  throws
{
  let anchor = try event(0x42, at: 12_000, body: littleEndian(1_790_000_000))
  let packet = try event(0x47, at: 12_000, body: body)
  let session = UUID()
  let decoded = Measurements(events: [anchor, packet], session: session, now: referenceTime)
  #expect(decoded.samples.count == 1)
  let sample = try #require(decoded.samples.first)
  #expect(sample.kind == .motionSeconds)
  #expect(sample.value == seconds)
  #expect(sample.start == referenceTime)
  #expect(sample.end == referenceTime)
  #expect(
    Measurements(events: [anchor, packet], session: session, now: referenceTime).samples
      == decoded.samples)
}

@Test(arguments: [
  [UInt8(10), 0, 0],
  [UInt8(10), 0, 0, 0, 64],
  [UInt8(10), 0, 0, 0, 0, 64],
])
func invalidMovementSummaryCannotBecomeMeasuredActivity(body: [UInt8]) throws {
  let anchor = try event(0x42, at: 12_000, body: littleEndian(1_790_000_000))
  let packet = try event(0x47, at: 12_000, body: body)
  #expect(
    Measurements(events: [anchor, packet], session: UUID(), now: referenceTime).samples.isEmpty)
}

@Test func movementNeedsItsOwnSessionClockAnchor() throws {
  let packet = try event(0x47, at: 12_000, body: [7, 0, 0, 0])
  let decoded = Measurements(events: [packet], session: UUID(), now: referenceTime)
  #expect(decoded.samples.isEmpty)
  #expect(decoded.undatedEvents == 1)
}

@Test func greenBeatsProduceOneQualityFilteredPacketMeanWithoutInventingBeatTimes() throws {
  let anchor = try event(0x42, at: 12_000, body: littleEndian(1_790_000_000))
  let body =
    greenBeat(ibi: 1_000, quality: 1) + greenBeat(ibi: 750, quality: 1)
    + greenBeat(ibi: 500, quality: 0) + greenBeat(ibi: 500, quality: 2)
    + greenBeat(ibi: 500, quality: 3) + greenBeat(ibi: 299, quality: 1)
    + greenBeat(ibi: 2_001, quality: 1)
  let packet = try event(0x80, at: 12_000, body: body)
  let session = UUID()
  let decoded = Measurements(events: [anchor, packet], session: session, now: referenceTime)
  #expect(decoded.samples.count == 1)
  #expect(decoded.samples.first?.kind == .heartRate)
  #expect(decoded.samples.first?.value == 70)
  #expect(decoded.samples.first?.start == referenceTime)
  #expect(decoded.samples.first?.end == referenceTime)
  #expect(
    Measurements(events: [anchor, packet], session: session, now: referenceTime).samples
      == decoded.samples)
  #expect(Measurements(events: [packet], session: session, now: referenceTime).samples.isEmpty)
  #expect(Measurements(events: [packet], session: session, now: referenceTime).undatedEvents == 1)
}

@Test func greenBeatPrecisionAndBoundaryIBIsArePreserved() throws {
  let anchor = try event(0x42, at: 12_000, body: littleEndian(1_790_000_000))
  let packet = try event(
    0x80, at: 12_000,
    body: greenBeat(ibi: 300, quality: 1) + greenBeat(ibi: 2_000, quality: 1)
      + greenBeat(ibi: 777, quality: 1))
  let decoded = Measurements(events: [anchor, packet], session: UUID(), now: referenceTime)
  let expected: Double = (200 + 30 + 60_000.0 / 777) / 3
  let actual = try #require(decoded.samples.first?.value)
  #expect(abs(actual - expected) < 0.000001)
}

@Test func malformedOrUnacceptedGreenBeatsProduceNoPhysiology() throws {
  let anchor = try event(0x42, at: 12_000, body: littleEndian(1_790_000_000))
  for body in [[], [125], greenBeat(ibi: 1_000, quality: 0), greenBeat(ibi: 0, quality: 1)] {
    let packet = try event(0x80, at: 12_000, body: body)
    #expect(
      Measurements(events: [anchor, packet], session: UUID(), now: referenceTime).samples.isEmpty)
  }
}

@Test func hrvAveragesWalkBackwardFromLastSample() throws {
  let anchor = try event(0x42, at: 12_000, body: littleEndian(1_790_000_000))
  let hrv = try event(0x5d, at: 12_000, body: [50, 40, 52, 42])
  let decoded = Measurements(events: [anchor, hrv], session: UUID(), now: referenceTime)
  let heart = decoded.samples.filter { $0.kind == .heartRate }
  #expect(heart.map(\.value) == [50, 52])
  #expect(heart.map(\.end) == [referenceTime.addingTimeInterval(-300), referenceTime])
  #expect(heart.first?.start == referenceTime.addingTimeInterval(-600))
  #expect(decoded.samples.filter { $0.kind == .hrvRMSSD }.map(\.value) == [40, 42])
}

@Test func undatedMeasurementsNeverAcquireTheSyncDate() throws {
  let hrv = try event(0x5d, at: 12_000, body: [50, 40])
  let decoded = Measurements(events: [hrv], session: UUID(), now: referenceTime)
  #expect(decoded.samples.isEmpty)
  #expect(decoded.undatedEvents == 1)
}

@Test func sentinelValuesAndMalformedBodiesAreNotExportable() throws {
  let anchor = try event(0x42, at: 12_000, body: littleEndian(1_790_000_000))
  let sentinel = try event(0x5d, at: 12_000, body: [255, 255, 0, 0])
  let malformed = try event(0x5d, at: 10_000, body: [50, 40, 10])
  #expect(
    Measurements(events: [anchor, sentinel, malformed], session: UUID(), now: referenceTime).samples
      .isEmpty)
}

@Test func exportIdentityIsStableAcrossRepeatedSyncsAndIsolatedAcrossResets() throws {
  let events = try [
    event(0x42, at: 12_000, body: littleEndian(1_790_000_000)),
    event(0x5d, at: 12_000, body: [50, 40]),
  ]
  let session = UUID()
  let first = Measurements(events: events, session: session, now: referenceTime)
  #expect(
    first.samples == Measurements(events: events, session: session, now: referenceTime).samples)
  #expect(
    first.samples.map(\.id)
      != Measurements(events: events, session: UUID(), now: referenceTime).samples.map(\.id))
}

@Test(arguments: [UInt32(1_789_999_000), UInt32(1_790_000_000)])
func clockCorrectionsPreserveFiveMinuteAverageDuration(correctedUnix: UInt32) throws {
  let events = try [
    event(0x42, at: 3_000, body: littleEndian(1_789_999_400)),
    event(0x42, at: 6_000, body: littleEndian(correctedUnix)),
    event(0x5d, at: 6_000, body: [50, 40]),
  ]
  let decoded = Measurements(events: events, session: UUID(), now: referenceTime)
  #expect(decoded.samples.count == 2)
  for sample in decoded.samples {
    #expect(sample.end == Date(timeIntervalSince1970: Double(correctedUnix)))
    #expect(sample.end.timeIntervalSince(sample.start) == 300)
  }
}

@Test func bedtimeCrossingClockCorrectionKeepsItsRecordedDuration() throws {
  let events = try [
    event(0x42, at: 3_000, body: littleEndian(1_789_999_500)),
    event(0x42, at: 6_000, body: littleEndian(1_789_999_700)),
    event(0x76, at: 9_000, body: littleEndian(3_000) + littleEndian(9_000)),
  ]
  let decoded = Measurements(events: events, session: UUID(), now: referenceTime)
  #expect(decoded.samples.count == 1)
  #expect(decoded.samples.first?.start == referenceTime.addingTimeInterval(-600))
  #expect(decoded.samples.first?.end == referenceTime)
}

@Test(arguments: [UInt32(2_000), UInt32(12_010)])
func averagesOutsideValidRingTimeAreNotExported(counter: UInt32) throws {
  let events = try [
    event(0x42, at: 12_000, body: littleEndian(1_790_000_000)),
    event(0x5d, at: counter, body: [50, 40]),
  ]
  let decoded = Measurements(events: events, session: UUID(), now: referenceTime)
  #expect(decoded.samples.isEmpty)
  #expect(decoded.undatedEvents == 1)
}

@Test func futureClockReferencesCannotDateMeasurements() throws {
  let events = try [
    event(0x42, at: 12_000, body: littleEndian(1_790_000_001)),
    event(0x5d, at: 9_000, body: [50, 40]),
  ]
  #expect(Measurements(events: events, session: UUID(), now: referenceTime).samples.isEmpty)
}

@Test func averageCannotStartBeforeTheSupportedCalendarRange() throws {
  let events = try [
    event(0x42, at: 12_000, body: littleEndian(1_577_836_800)),
    event(0x5d, at: 12_000, body: [50, 40]),
  ]
  #expect(Measurements(events: events, session: UUID(), now: referenceTime).samples.isEmpty)
}

@Test func sleepingTemperatureKeepsThirtySecondCadenceAcrossMissingSamples() throws {
  let events = try [
    event(0x42, at: 12_000, body: littleEndian(1_790_000_000)),
    event(0x75, at: 12_000, body: [0x48, 0x0d, 0, 0, 0xac, 0x0d]),
    event(0x46, at: 12_000, body: [0x48, 0x0d]),
  ]
  let samples = Measurements(events: events, session: UUID(), now: referenceTime).samples
  #expect(samples.map(\.kind) == [.skinTemperature, .skinTemperature])
  #expect(samples.map(\.value) == [34, 35])
  #expect(samples.map(\.end) == [referenceTime.addingTimeInterval(-60), referenceTime])
}

@Test func respirationRequiresValidSleepingWindow() throws {
  let events = try [
    event(0x42, at: 12_000, body: littleEndian(1_790_000_000)),
    event(0x6a, at: 12_000, body: [104, 0, 0, 0, 112, 0, 3, 1, 0, 0]),
    event(0x6a, at: 12_000, body: [104, 0, 0, 0, 112, 0, 3, 0, 0, 0]),
    event(0x6a, at: 12_000, body: [104, 0, 0, 0, 112, 0, 120, 1, 0, 0]),
  ]
  let samples = Measurements(events: events, session: UUID(), now: referenceTime).samples
  #expect(samples.count == 1)
  #expect(samples.first?.kind == .respiratoryRate)
  #expect(samples.first?.value == 14)
  #expect(samples.first?.start == samples.first?.end)
}

@Test func oxygenContinuationAndMissingValuesDoNotShiftRecordedTimes() throws {
  let events = try [
    event(0x42, at: 12_000, body: littleEndian(1_790_000_000)),
    event(0x6f, at: 12_000, body: [0, 97, 0, 98, 255]),
  ]
  let samples = Measurements(events: events, session: UUID(), now: referenceTime).samples
  #expect(samples.map(\.value) == [97, 98])
  #expect(samples.map(\.end) == [referenceTime.addingTimeInterval(-2), referenceTime])
}

@Test func activityUsesNonlinearMETScaleWithoutInventingStepsOrBinTimes() throws {
  let events = try [
    event(0x42, at: 12_000, body: littleEndian(1_790_000_000)),
    event(0x50, at: 12_000, body: [3, 10, 128, 144]),
  ]
  let samples = Measurements(events: events, session: UUID(), now: referenceTime).samples
  #expect(samples.count == 1)
  #expect(samples.first?.kind == .activityMET)
  #expect(abs((samples.first?.value ?? 0) - (1 + 12.8 + 16) / 3) < 0.0001)
  #expect(samples.first?.end == referenceTime)
}
