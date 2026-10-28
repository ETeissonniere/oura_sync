/// The native Gen 3 consumer delays evaluation until 39 oxygen samples are buffered.
/// These are signal-quality decisions, not a calibration or clinical confidence score.
struct OxygenQualityQueue {
  struct Sample: Equatable {
    let time: Int64
    let value: UInt8
  }

  struct Evaluation: Equatable {
    let sample: Sample
    let optical: OxygenOpticalBuffer.Quality
    let motion: Double
    let coverage: Int64
    let valid: Bool
  }

  private struct Motion {
    let time: Int64
    let value: UInt8
  }

  private(set) var samples: [Sample] = []
  private var motion: [Motion?] = [nil, nil, nil]
  private var motionWrite = 0

  @discardableResult
  mutating func add(_ sample: Sample) -> Bool {
    samples.append(sample)
    if samples.count > 39 { samples.removeFirst() }
    return samples.count == 39
  }

  mutating func addMotion(at time: Int64, value: UInt8) {
    motion[motionWrite] = Motion(time: time, value: value)
    motionWrite = (motionWrite + 1) % 3
  }

  func evaluate(_ index: Int, optical: OxygenOpticalBuffer) -> Evaluation {
    let sample = samples[index]
    var weighted = 0.0
    var coverage: Int64 = 0
    // Physical slot order is intentional: the native overlap cap makes it significant.
    for record in motion.compactMap({ $0 }) {
      let overlap = max(
        0, min(sample.time, record.time) - max(sample.time - 6000, record.time - 30000))
      guard coverage + overlap <= 6999 else { continue }
      weighted += Double(overlap) * Double(record.value)
      coverage += overlap
    }
    let motion = weighted / Double(max(6000, coverage))
    let quality = optical.quality(channel: 1, at: sample.time)
    let valid =
      (70...100).contains(sample.value) && motion <= 10
      && (motion >= 2 || (quality.perfusion >= 0.002 && quality.pulses >= 2))
    return Evaluation(
      sample: sample, optical: quality, motion: motion, coverage: coverage, valid: valid)
  }
}
