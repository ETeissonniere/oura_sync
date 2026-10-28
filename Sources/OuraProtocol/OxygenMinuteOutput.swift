/// Native minute aggregation. Quality describes the fraction of received samples
/// accepted, not temporal coverage or calibration confidence.
enum OxygenMinuteOutput {
  struct Reading: Equatable {
    let time: Int64
    let value: UInt8
    let quality: Bool
  }

  static func readings(from batch: OxygenEventProcessor.Batch) -> [Reading] {
    let samples = batch.quality.map(\.sample)
    let rejected = OxygenDipDetector.detect(samples).filter {
      OxygenDipClassifier.probability(of: $0, in: batch) <= 0.5
    }
    let accepted = batch.quality.map { evaluation in
      evaluation.valid
        && !rejected.contains {
          samples[$0.start].time < evaluation.sample.time
            && evaluation.sample.time <= samples[$0.end].time
        }
    }
    return aggregate(samples: samples, accepted: accepted)
  }

  static func aggregate(samples: [OxygenQualityQueue.Sample], accepted: [Bool]) -> [Reading] {
    guard samples.count == accepted.count, let first = samples.first else { return [] }
    var start = first.time
    var total = 0
    var count = 0
    var sum = 0
    var result: [Reading] = []
    for (index, sample) in samples.enumerated() {
      if sample.time - start >= 60000 {
        if count > 0 {
          result.append(
            Reading(
              time: samples[index - 1].time,
              value: UInt8((sum + count / 2) / count),
              quality: Double(count) / Double(total) >= 0.1))
        }
        start = sample.time
        total = 0
        count = 0
        sum = 0
      }
      if accepted[index] {
        count += 1
        sum += Int(sample.value)
      }
      total += 1
    }
    // The native consumer omits an unfinished trailing minute, even at session end.
    return result
  }
}
