/// Processes one ring session in recorded order. Times are milliseconds on one clock.
/// Completed batches still require dip classification before becoming display readings.
struct OxygenEventProcessor {
  struct Batch {
    let quality: [OxygenQualityQueue.Evaluation]
    let optical: [OxygenOpticalBuffer.Reading]
  }

  private var optical = OxygenOpticalBuffer()
  private var queue = OxygenQualityQueue()
  private var evaluated: [OxygenQualityQueue.Evaluation] = []
  private var baselines: [OxygenOpticalBuffer.Reading] = []
  private var ended = false

  mutating func process(tag: UInt8, body: [UInt8], at time: Int64) -> [Batch] {
    guard time >= 0, time <= Int64.max - 30000 else { return [] }
    var completed: [Batch] = []
    switch tag {
    case 0x47:
      if !ended, let first = body.first { queue.addMotion(at: time, value: first & 31) }
    case 0x6c:
      if body.count >= 3, body[0] == 4 {
        if body[1] <= 1 {
          if ended { restart() }
        } else if body[1] < 12 {
          completed.append(finish(ended: true, skipOldest: true))
        }
      }
    case 0x6e:
      if optical.addPulses(body, endingAt: time), ended { restart() }
    case 0x77:
      let result = optical.addBaselines(body, endingAt: time)
      if ended {
        switch result {
        case .decoded, .skipped: restart()
        case .malformed, .sequenceGap: break
        }
      }
    case 0x6f:
      if (2...14).contains(body.count) {
        if ended { restart() }
        let terminal = body.last == 255
        let values = body.dropFirst().dropLast(terminal ? 1 : 0)
        var end = time - 5000
        if terminal, let previous = queue.samples.last {
          let expectedEnd = previous.time + Int64(values.count) * 1000
          if abs(end - expectedEnd) <= 2299 { end = expectedEnd }
        }
        for (index, value) in values.enumerated() {
          let ready = queue.add(
            .init(time: end - Int64(values.count - 1 - index) * 1000, value: value))
          let last = terminal && index == values.count - 1
          if evaluated.count >= 1760 || last {
            completed.append(finish(ended: last))
          } else if ready {
            evaluated.append(queue.evaluate(0, optical: optical))
          }
        }
      }
    default: break
    }
    baselines.append(contentsOf: optical.drain(flush: ended))
    return completed
  }

  private mutating func restart() {
    optical.reset(ended: false)
    queue = OxygenQualityQueue()
    evaluated.removeAll(keepingCapacity: true)
    baselines.removeAll(keepingCapacity: true)
    ended = false
  }

  private mutating func finish(ended: Bool, skipOldest: Bool = false) -> Batch {
    baselines.append(contentsOf: optical.drain(flush: true))
    // Feature-stop events skip the already-consumed oldest slot; terminal oxygen
    // packets and full batches include it. Short feature-stop queues also skip it.
    for index in queue.samples.indices where !skipOldest || index > 0 {
      evaluated.append(queue.evaluate(index, optical: optical))
    }
    let batch = Batch(quality: evaluated, optical: baselines)
    evaluated = []
    baselines = []
    queue = OxygenQualityQueue()
    optical.reset(ended: ended)
    self.ended = ended
    return batch
  }
}
