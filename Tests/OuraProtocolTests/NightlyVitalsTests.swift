import Foundation
import Testing

@testable import OuraProtocol

private let nightlyReference = Date(timeIntervalSince1970: 1_790_000_000)
private let nightlySession = UUID(uuidString: "A1000000-0000-0000-0000-000000000090")!

private func vital(
  _ id: String, _ kind: MeasurementKind, _ start: Double, _ end: Double, _ value: Double
) -> OuraProtocol.Measurement {
  OuraProtocol.Measurement(
    id: id, kind: kind, start: nightlyReference.addingTimeInterval(start),
    end: nightlyReference.addingTimeInterval(end), value: value)
}

@Test func nightlyVitalsUseFullyContainedFiveMinuteAverages() throws {
  let measurements = [
    vital("bed", .inBed, 0, 3_600, 1),
    vital("start", .heartRate, 0, 300, 50),
    vital("end", .heartRate, 3_300, 3_600, 60),
    vital("before", .heartRate, -1, 299, 90),
    vital("after", .heartRate, 3_301, 3_601, 90),
    vital("instant", .heartRate, 600, 600, 120),
    vital("short", .heartRate, 600, 899, 120),
    vital("long", .heartRate, 600, 901, 120),
    vital("hrv", .hrvRMSSD, 300, 600, 42),
    vital("instantHRV", .hrvRMSSD, 900, 900, 100),
  ]
  let night = try #require(
    NightlyVitals.calculate(measurements: measurements, session: nightlySession).first)
  #expect(night.heartRate == NightlyVital(average: 55, minimum: 50, maximum: 60, count: 2))
  #expect(night.hrv == NightlyVital(average: 42, minimum: 42, maximum: 42, count: 1))
  #expect(night.start == nightlyReference)
  #expect(night.end == nightlyReference.addingTimeInterval(3_600))
  #expect(night.session == nightlySession)
}

@Test func missingNightlyVitalsStayUnavailableWhileTheBedtimeRemains() throws {
  let measurements = [
    vital("bed", .inBed, 0, 3_600, 1),
    vital("zero", .heartRate, 0, 300, 0),
    vital("negative", .hrvRMSSD, 0, 300, -1),
    vital("nan", .respiratoryRate, 300, 300, .nan),
    vital("infinity", .oxygenSaturation, 300, 300, .infinity),
    vital("wrongKind", .activityMET, 300, 300, 2),
    vital("oneTemperature", .skinTemperature, 300, 300, 35),
  ]
  let nights = NightlyVitals.calculate(measurements: measurements, session: nightlySession)
  #expect(nights.count == 1)
  let night = try #require(nights.first)
  #expect(night.heartRate == nil)
  #expect(night.hrv == nil)
  #expect(night.respiratoryRate == nil)
  #expect(night.oxygenSaturation == nil)
  #expect(night.skinTemperature == nil)
}

@Test func nightlyDuplicatesDoNotGainWeightAndConflictsHaveNoWinner() throws {
  let measurements = [
    vital("bedB", .inBed, 0, 3_600, 1), vital("bedA", .inBed, 0, 3_600, 1),
    vital("hrA", .heartRate, 0, 300, 50), vital("hrB", .heartRate, 0, 300, 50),
    vital("conflictA", .heartRate, 300, 600, 60), vital("conflictB", .heartRate, 300, 600, 61),
    vital("hrv", .hrvRMSSD, 0, 300, 40),
    vital("breathA", .respiratoryRate, 900, 900, 14),
    vital("breathB", .respiratoryRate, 900, 900, 14),
    vital("breathOther", .respiratoryRate, 1_200, 1_200, 16),
    vital("oxygenA", .oxygenSaturation, 900, 900, 97),
    vital("oxygenB", .oxygenSaturation, 900, 900, 98),
  ]
  let nights = NightlyVitals.calculate(measurements: measurements, session: nightlySession)
  #expect(nights.count == 1)
  #expect(
    nights
      == NightlyVitals.calculate(measurements: measurements.reversed(), session: nightlySession))
  let night = try #require(nights.first)
  #expect(night.heartRate == NightlyVital(average: 50, minimum: 50, maximum: 50, count: 1))
  #expect(night.hrv?.average == 40)
  #expect(night.respiratoryRate == NightlyVital(average: 15, minimum: 14, maximum: 16, count: 2))
  #expect(night.oxygenSaturation == nil)
  let stable = NightlyVitals.calculate(
    measurements: [vital("bedA", .inBed, 0, 3_600, 1)], session: nightlySession)
  #expect(night.id == stable.first?.id)
}

@Test func nightlyPointMeasurementsRespectInclusiveWindowBoundaries() throws {
  let measurements = [
    vital("bed", .inBed, 0, 3_600, 1),
    vital("breathStart", .respiratoryRate, 0, 0, 14),
    vital("breathEnd", .respiratoryRate, 3_600, 3_600, 16),
    vital("breathBefore", .respiratoryRate, -1, -1, 30),
    vital("breathAfter", .respiratoryRate, 3_601, 3_601, 30),
    vital("oxygen", .oxygenSaturation, 3_600, 3_600, 98),
  ]
  let night = try #require(
    NightlyVitals.calculate(measurements: measurements, session: nightlySession).first)
  #expect(night.respiratoryRate?.average == 15)
  #expect(night.respiratoryRate?.count == 2)
  #expect(night.oxygenSaturation?.average == 98)
}

@Test func independentNightsKeepTheirOwnVitalsAndTemperatureWindows() throws {
  var measurements = [
    vital("night1", .inBed, 0, 3_600, 1), vital("night2", .inBed, 86_400, 90_000, 1),
    vital("hr1", .heartRate, 0, 300, 50), vital("hr2", .heartRate, 86_400, 86_700, 70),
    vital("hrv1", .hrvRMSSD, 0, 300, 40), vital("hrv2", .hrvRMSSD, 86_400, 86_700, 60),
  ]
  for index in 0..<120 {
    let offset = Double(index) * 30
    measurements.append(vital("temp1.\(index)", .skinTemperature, offset, offset, 35))
    measurements.append(
      vital("temp2.\(index)", .skinTemperature, 86_400 + offset, 86_400 + offset, 34))
  }
  let nights = NightlyVitals.calculate(
    measurements: measurements.reversed(), session: nightlySession)
  #expect(nights.count == 2)
  #expect(nights.map { $0.heartRate?.average } == [50, 70])
  #expect(nights.map { $0.hrv?.average } == [40, 60])
  #expect(nights.map(\.skinTemperature) == [35, 34])
  let otherSession = UUID()
  let other = NightlyVitals.calculate(measurements: measurements, session: otherSession)
  #expect(other.map(\.session) == [otherSession, otherSession])
  #expect(other.map(\.id) != nights.map(\.id))
}

@Test func invalidBedtimeWindowsDoNotProduceNightlyVitals() {
  let measurements = [
    vital("empty", .inBed, 0, 0, 1),
    vital("reversed", .inBed, 300, 0, 1),
    vital("tooLong", .inBed, 0, 86_401, 1),
    vital("undated", .inBed, 0, .infinity, 1),
    vital("invalidValue", .inBed, 0, 3_600, 0),
  ]
  #expect(NightlyVitals.calculate(measurements: measurements, session: nightlySession).isEmpty)
  #expect(
    NightlyVitals.calculate(
      measurements: [vital("fullDay", .inBed, 0, 86_400, 1)], session: nightlySession
    ).count == 1)
}
