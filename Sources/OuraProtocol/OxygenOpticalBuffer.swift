/// Preserves the Gen 3 consumer's 180-slot optical buffers and packet order.
/// Zero timestamps mean unresolved; sorting would change pulse-to-baseline matching.
struct OxygenOpticalBuffer {
  struct Quality: Equatable {
    let amplitude: Double
    let baseline: Double
    let pulses: Int
    var perfusion: Double { baseline == 0 ? 0 : amplitude / baseline }
  }

  struct Reading: Equatable {
    let channel: Int
    let time: Int64
    let value: UInt32
  }

  private struct Entry {
    var time: Int64 = 0
    var value: UInt32 = 0
    var sequence: UInt8 = 0
    var valid = false
    var resolved = false
  }

  private struct Buffer {
    var entries = Array(repeating: Entry(), count: 180)
    var read = 0
    var write = 0
    var count: Int { (write - read + 180) % 180 }

    mutating func append(_ entry: Entry) {
      entries[write] = entry
      write = (write + 1) % 180
    }

    mutating func moveRead(to index: Int) {
      if index != write && read != write { read = index }
    }
  }

  private var baselines = [Buffer(), Buffer()]
  private var pulses = [Buffer(), Buffer()]

  mutating func reset(ended: Bool) {
    let retained = baselines.map { $0.entries[($0.write + 179) % 180] }
    baselines = [Buffer(), Buffer()]
    pulses = [Buffer(), Buffer()]
    if !ended {
      for channel in 0..<2 { baselines[channel].entries[179] = retained[channel] }
    }
  }

  @discardableResult
  mutating func addBaselines(_ bytes: [UInt8], endingAt time: Int64)
    -> OxygenOpticalPacket.Baselines
  {
    guard let header = bytes.first else { return .malformed }
    let channel = Int(header >> 7)
    let last = baselines[channel].entries[(baselines[channel].write + 179) % 180]
    let previous: OxygenOpticalPacket.Baseline? =
      last.time == 0 ? nil : .init(value: last.value, sequence: last.sequence)
    let result = OxygenOpticalPacket.baselines(bytes, previous: previous)
    if case .decoded(let samples) = result {
      for (index, sample) in samples.enumerated() {
        baselines[channel].append(
          Entry(
            time: index == samples.count - 1 ? time : 0, value: sample.value,
            sequence: sample.sequence))
      }
    }
    return result
  }

  @discardableResult
  mutating func addPulses(_ bytes: [UInt8], endingAt time: Int64) -> Bool {
    guard let decoded = OxygenOpticalPacket.pulses(bytes, endingAt: time) else { return false }
    let channel = Int(bytes[0] >> 7)
    for pulse in decoded {
      pulses[channel].append(
        Entry(
          time: pulse.time, value: pulse.amplitude, sequence: pulse.sequence, valid: pulse.valid))
    }
    return true
  }

  mutating func drain(flush: Bool = false) -> [Reading] {
    var result: [Reading] = []
    while max(baselines[0].count, baselines[1].count) > (flush ? 0 : 39) {
      let times = (0..<2).map { Self.resolve(&baselines[$0], pulses: pulses[$0]) }
      let channel = Self.earlierChannel(times)
      let time = times[channel]
      let pulseTimes = pulses.map { $0.read == $0.write ? 0 : $0.entries[$0.read].time }
      let pulseChannel = Self.earlierChannel(pulseTimes)
      if pulseTimes[pulseChannel] != 0 && (time == 0 || pulseTimes[pulseChannel] < time) {
        pulses[pulseChannel].read = (pulses[pulseChannel].read + 1) % 180
      } else {
        guard time != 0 else { break }
        let entry = baselines[channel].entries[baselines[channel].read]
        result.append(Reading(channel: channel, time: entry.time, value: entry.value))
        baselines[channel].read = (baselines[channel].read + 1) % 180
      }
    }
    return result
  }

  func quality(channel: Int, at time: Int64) -> Quality {
    let start = time - 6000
    let window = pulses[channel].entries.filter { $0.time >= start && $0.time < time }
    let invalidTimes = Set(window.filter { !$0.valid }.map(\.time))
    let valid = window.filter(\.valid)
    // Baselines need no matching valid pulse, but an invalid pulse at the same
    // timestamp excludes that baseline. Retained slots matter after draining.
    let baseline = baselines[channel].entries.reduce(0.0) { sum, entry in
      entry.time >= start && entry.time < time && !invalidTimes.contains(entry.time)
        ? sum + Double(entry.value) : sum
    }
    return Quality(
      amplitude: valid.reduce(0.0) { $0 + Double($1.value) }, baseline: baseline,
      pulses: valid.count)
  }

  private static func earlierChannel(_ times: [Int64]) -> Int {
    if times[0] == 0 { return times[1] == 0 ? 0 : 1 }
    return times[1] != 0 && times[1] < times[0] ? 1 : 0
  }

  private static func resolve(_ buffer: inout Buffer, pulses: Buffer) -> Int64 {
    var anchor = buffer.read
    while anchor != buffer.write {
      let entry = buffer.entries[anchor]
      if entry.time != 0 {
        if entry.resolved {
          buffer.moveRead(to: anchor)
          return entry.time
        }
        var cursor = pulses.read
        var matched: Int?
        while cursor != pulses.write {
          let pulse = pulses.entries[cursor]
          let delta = pulse.time.subtractingReportingOverflow(entry.time)
          if entry.time > 0, pulse.sequence == (entry.sequence + 1) & 15,
            !delta.overflow, delta.partialValue > -2300, delta.partialValue < 2300
          {
            matched = (cursor + 179) % 180
            break
          }
          cursor = (cursor + 1) % 180
        }
        guard var pulse = matched else {
          buffer.moveRead(to: (buffer.read + 1) % 180)
          return 0
        }
        let beforeBaseline = (buffer.read + 179) % 180
        let beforePulse = (pulses.read + 179) % 180
        var index = anchor
        var time = entry.time
        while index != beforeBaseline && pulse != beforePulse {
          time = pulses.entries[pulse].time
          buffer.entries[index].time = time
          buffer.entries[index].resolved = true
          index = (index + 179) % 180
          pulse = (pulse + 179) % 180
        }
        if index != beforeBaseline { buffer.moveRead(to: (index + 1) % 180) }
        return time
      }
      anchor = (anchor + 1) % 180
    }
    buffer.moveRead(to: (buffer.read + 1) % 180)
    return 0
  }
}
