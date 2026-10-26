import Foundation
import Testing

@testable import OuraProtocol

private func bucketSample(_ value: Double, at seconds: TimeInterval) -> OuraProtocol.Measurement {
  let end = Date(timeIntervalSince1970: seconds)
  return Measurement(
    id: "\(seconds).\(value)", kind: .heartRate, start: end.addingTimeInterval(-300),
    end: end, value: value)
}

private var utcBucketsCalendar: Calendar {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(secondsFromGMT: 0)!
  return calendar
}

@Test func hourlyBucketsPreserveGapsAndUseSampleEnd() {
  let buckets = MeasurementBuckets(
    samples: [bucketSample(80, at: 10_900), bucketSample(60, at: 3_600)], interval: .hour,
    calendar: utcBucketsCalendar
  ).values
  #expect(buckets.map(\.start.timeIntervalSince1970) == [3_600, 10_800])
  #expect(buckets.map(\.end.timeIntervalSince1970) == [7_200, 14_400])
  #expect(buckets.map(\.id) == buckets.map(\.start))
}

@Test func dailyBucketMeanWeightsEverySampleRatherThanHourlyMeans() throws {
  let bucket = try #require(
    MeasurementBuckets(
      samples: [
        bucketSample(40, at: 100), bucketSample(60, at: 200), bucketSample(110, at: 4_000),
      ],
      interval: .day, calendar: utcBucketsCalendar
    ).values.first)
  #expect(bucket.count == 3)
  #expect(abs(bucket.average - 70) < 0.000_001)
  #expect(bucket.minimum == 40)
  #expect(bucket.maximum == 110)
  #expect(bucket.start.timeIntervalSince1970 == 0)
  #expect(bucket.end.timeIntervalSince1970 == 86_400)
}

@Test func invalidValuesDoNotCreateOrDistortBuckets() {
  let buckets = MeasurementBuckets(
    samples: [
      bucketSample(.nan, at: 100), bucketSample(.infinity, at: 200), bucketSample(72, at: 4_000),
    ],
    interval: .hour, calendar: utcBucketsCalendar
  ).values
  #expect(buckets.count == 1)
  #expect(buckets.first?.average == 72)
  #expect(buckets.first?.count == 1)
}

@Test func dailyBucketsRespectDaylightSavingDayBounds() throws {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
  let noon = try #require(
    calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12)))
  let bucket = try #require(
    MeasurementBuckets(
      samples: [bucketSample(65, at: noon.timeIntervalSince1970)], interval: .day,
      calendar: calendar
    ).values.first)
  #expect(bucket.end.timeIntervalSince(bucket.start) == 23 * 3_600)
  #expect(calendar.component(.hour, from: bucket.start) == 0)
  #expect(calendar.component(.hour, from: bucket.end) == 0)
}
