import CryptoKit
import Foundation

public enum MeasurementKind: String, Codable, Sendable {
  case heartRate, hrvRMSSD, inBed, skinTemperature, respiratoryRate, activityMET, oxygenSaturation
  case motionSeconds
}

public struct Measurement: Identifiable, Codable, Sendable, Equatable {
  public let id: String
  public let kind: MeasurementKind
  public let start: Date
  public let end: Date
  public let value: Double
}

public struct Measurements: Sendable {
  public let samples: [Measurement]
  public let undatedEvents: Int

  public init(events: [RingEvent], session: UUID, now: Date = .now) {
    let anchors = events.filter { $0.tag == 0x42 && $0.body.count >= 4 }
      .compactMap { event -> (counter: Int64, unix: TimeInterval)? in
        let unix = TimeInterval(Array(event.body).uint32(at: 0))
        guard unix >= 1_577_836_800, unix <= now.timeIntervalSince1970 else { return nil }
        return (Int64(event.timestamp), unix)
      }.sorted { $0.counter < $1.counter }
    func interval(from startCounter: Int64, to endCounter: Int64) -> (start: Date, end: Date)? {
      guard startCounter >= 0, endCounter >= startCounter,
        let anchor = anchors.last(where: { $0.counter <= endCounter }) ?? anchors.first
      else { return nil }
      // A clock correction between the endpoints must not stretch or reverse a
      // recorded interval. The latest sample's anchor dates the entire window.
      let end = anchor.unix + Double(endCounter - anchor.counter) / 10
      let start = end - Double(endCounter - startCounter) / 10
      guard start >= 1_577_836_800, end <= now.timeIntervalSince1970, end >= start else {
        return nil
      }
      return (Date(timeIntervalSince1970: start), Date(timeIntervalSince1970: end))
    }
    var result: [Measurement] = []
    var undated = 0
    var oxygen = OxygenEventProcessor()
    for event in events {
      let batches = oxygen.process(
        tag: event.tag, body: Array(event.body), at: Int64(event.timestamp) * 100)
      for batch in batches {
        for reading in OxygenMinuteOutput.readings(from: batch) where reading.quality {
          guard reading.time >= 0,
            let anchor = anchors.last(where: { $0.counter * 100 <= reading.time }) ?? anchors.first
          else {
            undated += 1
            continue
          }
          let unix = anchor.unix + Double(reading.time - anchor.counter * 100) / 1000
          guard unix >= 1_577_836_800, unix <= now.timeIntervalSince1970 else {
            undated += 1
            continue
          }
          let date = Date(timeIntervalSince1970: unix)
          result.append(
            Measurement(
              id: "\(session.uuidString).oxygen.v1.\(reading.time)",
              kind: .oxygenSaturation, start: date, end: date, value: Double(reading.value)))
        }
      }
    }
    for event in events where [0x5d, 0x75, 0x6a, 0x50, 0x80, 0x47].contains(event.tag) {
      let bytes = Array(event.body)
      let digest = SHA256.hash(data: event.body).map { String(format: "%02x", $0) }.joined()
      let prefix = "\(session.uuidString).\(event.tag).\(event.timestamp).\(digest)"
      switch event.tag {
      case 0x75, 0x6a, 0x50, 0x80, 0x47:
        let kind: MeasurementKind
        let values: [Double]
        switch event.tag {
        case 0x47:
          guard bytes.count >= 4 else { continue }
          if bytes.count >= 5 && bytes[4] & 0x40 != 0 { continue }
          if bytes.count >= 6 && bytes[5] & 0x40 != 0 { continue }
          // The native motion summary counts seconds, but its window cadence is
          // not established. Preserve each observation without inventing a span.
          kind = .motionSeconds
          values = [Double(bytes[0] & 0x1f)]
        case 0x80:
          guard !bytes.isEmpty, bytes.count.isMultiple(of: 2) else { continue }
          let accepted = stride(from: 0, to: bytes.count, by: 2).compactMap { index -> Double? in
            let ibi = (Int(bytes[index]) << 3) | Int(bytes[index + 1] & 7)
            let quality = (bytes[index + 1] >> 3) & 3
            guard quality == 1, (300...2_000).contains(ibi) else { return nil }
            return 60_000 / Double(ibi)
          }
          guard !accepted.isEmpty else { continue }
          // Individual beat timestamps are not verified. Keep one quality-filtered
          // packet mean at the ring's event time, without inferring HRV or a duration.
          kind = .heartRate
          values = [accepted.reduce(0, +) / Double(accepted.count)]
        case 0x75:
          // Generic 0x46 temperatures include device/ambient channels. Only
          // the dedicated sleep stream is treated as skin temperature.
          guard !bytes.isEmpty, bytes.count.isMultiple(of: 2) else { continue }
          let temperatures = stride(from: 0, to: bytes.count, by: 2).map {
            Double(Int16(bitPattern: UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8)) / 100
          }
          guard temperatures.allSatisfy({ (-40...85).contains($0) }) else { continue }
          kind = .skinTemperature
          values = temperatures
        case 0x6a:
          guard bytes.count >= 10, bytes[6] < 120, bytes[7] == 1 else { continue }
          let breaths = Double(bytes[4]) / 8
          guard (4...40).contains(breaths) else { continue }
          kind = .respiratoryRate
          values = [breaths]
        case 0x50:
          guard bytes.count >= 2 else { continue }
          kind = .activityMET
          values = bytes.dropFirst().map {
            $0 < 128 ? Double($0) / 10 : 12.8 + Double($0 - 128) / 5
          }
        default: continue
        }
        guard !values.isEmpty else { continue }
        // Activity bin direction is not yet established. Show its packet mean
        // instead of assigning minute timestamps or inventing a step count.
        let readings = kind == .activityMET ? [values.reduce(0, +) / Double(values.count)] : values
        let spacing: Int64 = kind == .skinTemperature ? 300 : 0
        for (index, value) in readings.enumerated() {
          if kind == .skinTemperature && value <= 0 { continue }
          let counter = Int64(event.timestamp) - Int64(readings.count - 1 - index) * spacing
          guard let window = interval(from: counter, to: counter) else {
            undated += 1
            continue
          }
          result.append(
            Measurement(
              id: "\(prefix).\(kind.rawValue).\(index)", kind: kind, start: window.start,
              end: window.end,
              value: value))
        }
      case 0x5d:
        guard !bytes.isEmpty, bytes.count.isMultiple(of: 2) else { continue }
        let count = bytes.count / 2
        for index in 0..<count {
          // The packet timestamp marks the LAST five-minute average, not the first.
          let counter = Int64(event.timestamp) - Int64(count - 1 - index) * 3_000
          guard let window = interval(from: counter - 3_000, to: counter) else {
            undated += 1
            continue
          }
          let heartRate = Double(bytes[index * 2])
          let rmssd = Double(bytes[index * 2 + 1])
          if (30...220).contains(heartRate) {
            result.append(
              Measurement(
                id: "\(prefix).\(index).hr", kind: .heartRate,
                start: window.start, end: window.end, value: heartRate))
          }
          // 0 and 255 are not exported as measured physiology.
          if rmssd > 0 && rmssd < 255 {
            result.append(
              Measurement(
                id: "\(prefix).\(index).hrv", kind: .hrvRMSSD,
                start: window.start, end: window.end, value: rmssd))
          }
        }
      default: break
      }
    }
    for bedtime in BedtimeWindow.latest(in: events) {
      guard let window = interval(from: bedtime.start, to: bedtime.end) else {
        undated += 1
        continue
      }
      // A detected bedtime interval alone does not establish sleep stages.
      result.append(
        Measurement(
          id: "\(session.uuidString).bed.\(bedtime.identityStart)", kind: .inBed,
          start: window.start, end: window.end, value: 1))
    }
    samples = result.sorted { $0.start < $1.start }
    undatedEvents = undated
  }
}
