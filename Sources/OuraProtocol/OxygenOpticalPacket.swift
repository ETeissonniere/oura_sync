/// Gen 3 optical packet primitives, not calibrated oxygen measurements.
/// Recovered from Oura Android 7.15.0 libappecore.so: 0x120500 (DC), 0x11fdbc (pulses).
/// Binary SHA-256: 0fefc6a53b2ec9a09ce4081ff3a91807f29b7af788aab1a8885f8f8cdc8548e9.
enum OxygenOpticalPacket {
  struct Baseline: Equatable {
    let value: UInt32
    let sequence: UInt8
  }

  enum Baselines: Equatable {
    case malformed, sequenceGap, skipped
    case decoded([Baseline])
  }

  struct Pulse: Equatable {
    let time: Int64
    let amplitude: UInt32
    let sequence: UInt8
    let valid: Bool
  }

  static func baselines(_ bytes: [UInt8], previous: Baseline?) -> Baselines {
    guard let header = bytes.first else { return .malformed }
    let reset = header & 0x40 != 0
    let count = bytes.count - (reset ? 3 : 1)
    guard (1...(reset ? 11 : 13)).contains(count) else { return .malformed }
    let sequence = Int(header & 15)
    let first = (sequence - count + 17) & 15
    var value: UInt32
    var samples: [Baseline] = []
    if reset {
      value = UInt32(bytes[1]) | UInt32(bytes[2]) << 8 | UInt32(bytes[3]) << 16
      // The embedded Gen 3 configuration skips the whole packet before changing state.
      guard value < 0x80000 else { return .skipped }
      samples.append(Baseline(value: value, sequence: UInt8(first)))
    } else {
      guard let previous, (Int(previous.sequence) + 1) & 15 == first else {
        return .sequenceGap
      }
      value = previous.value
    }
    let scale = Int32(1 << ((header >> 4) & 3))
    for byte in bytes.dropFirst(reset ? 4 : 1) {
      let delta = Int32(Int8(bitPattern: byte)) * scale
      value = value &+ UInt32(bitPattern: delta)
      samples.append(Baseline(value: value, sequence: UInt8((first + samples.count) & 15)))
    }
    return .decoded(samples)
  }

  static func pulses(_ bytes: [UInt8], endingAt time: Int64) -> [Pulse]? {
    guard bytes.count == 13 else { return nil }
    let valid = (0..<6).map { bytes[$0 + 1] != 250 || bytes[$0 + 7] != 0 }
    let intervals: [Int64] = (0..<6).map { index in
      let nearest = (0..<6).filter { valid[$0] }.min {
        abs($0 - index) < abs($1 - index)
      }
      return nearest.map { Int64(bytes[$0 + 1]) * 8 } ?? 750
    }
    var timestamp = time
    var result: [Pulse] = []
    for index in stride(from: 5, through: 0, by: -1) {
      result.append(
        Pulse(
          time: timestamp, amplitude: UInt32(bytes[index + 7]) << ((bytes[0] >> 4) & 7),
          sequence: UInt8((Int(bytes[0] & 15) - 5 + index + 16) & 15), valid: valid[index]))
      if index > 0 {
        let subtraction = timestamp.subtractingReportingOverflow(intervals[index])
        guard !subtraction.overflow else { return nil }
        timestamp = subtraction.partialValue
      }
    }
    return result.reversed()
  }
}
