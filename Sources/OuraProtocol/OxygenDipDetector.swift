/// Reconstructs candidate dips before optical classification. Sample order is
/// significant: the ring can emit slightly overlapping packet timestamps.
enum OxygenDipDetector {
  struct Dip: Equatable {
    let start: Int
    let end: Int
    let bottom: Int
    let depth: UInt8
  }

  private struct Pool {
    var start: Int
    var end: Int
  }

  static func detect(_ samples: [OxygenQualityQueue.Sample]) -> [Dip] {
    guard samples.count > 2, samples.count <= 1800,
      let minimum = samples.map(\.value).min(), let maximum = samples.map(\.value).max(),
      Int(maximum) - Int(minimum) > 2
    else { return [] }
    var pools: [Pool] = []
    for level in Int(minimum)...Int(maximum) {
      var fresh: [Pool] = []
      var index = 1
      while index < samples.count {
        guard samples[index].value == level, samples[index - 1].value != level else {
          index += 1
          continue
        }
        let start = index
        while index + 1 < samples.count, samples[index + 1].value == level { index += 1 }
        let end = index
        index += 1
        guard index < samples.count else { continue }
        let left = pools.lastIndex {
          $0.end == start - 1 && samples[start].time - samples[$0.end].time < 2_000_000
        }
        let right = pools.lastIndex {
          $0.start == end + 1 && samples[$0.start].time - samples[end].time < 2_000_000
        }
        if let left, let right {
          let middle = start + (end - start) / 2
          pools[left].end = middle
          pools[right].start = middle + 1
        } else if let left {
          pools[left].end = end
        } else if let right {
          pools[right].start = start
        } else {
          fresh.append(Pool(start: start, end: end))
        }
      }
      pools.append(contentsOf: fresh)
      pools.sort { $0.start < $1.start }
    }
    clean(&pools, samples: samples, limit: 10000)
    var index = 0
    while index + 1 < pools.count {
      let pool = pools[index]
      let duration = samples[pool.end].time - samples[pool.start].time
      let first = Int(samples[pool.start].value)
      if duration <= 150000, !recovered(pool, samples: samples),
        first - Int(samples[pool.end].value) >= 2, pool.end + 1 == pools[index + 1].start
      {
        var next = index + 1
        while next < pools.count {
          let combined = Pool(start: pool.start, end: pools[next].end)
          let combinedDuration = samples[combined.end].time - samples[combined.start].time
          if combinedDuration > 180000 { break }
          if Int(samples[combined.end].value) > first - 2 || recovered(combined, samples: samples) {
            pools[index].end = combined.end
            pools.removeSubrange((index + 1)...next)
            break
          }
          if next + 1 < pools.count, pools[next].end + 1 != pools[next + 1].start { break }
          if combinedDuration > 150000 { break }
          next += 1
        }
      }
      index += 1
    }
    clean(&pools, samples: samples, limit: 1000)
    return pools.compactMap { pool in
      let duration = samples[pool.end].time - samples[pool.start].time
      guard duration >= 0, duration <= 180000, recovered(pool, samples: samples) else { return nil }
      var bottom = pool.start
      for index in pool.start...pool.end where samples[index].value <= samples[bottom].value {
        bottom = index
      }
      return Dip(
        start: pool.start, end: pool.end, bottom: bottom,
        depth: samples[pool.start].value - samples[bottom].value)
    }
  }

  private static func recovered(_ pool: Pool, samples: [OxygenQualityQueue.Sample]) -> Bool {
    let values = samples[pool.start...pool.end].map { Int($0.value) }
    guard let minimum = values.min(), let maximum = values.max() else { return false }
    return Int(samples[pool.start].value) - minimum >= 3
      && Int(samples[pool.end].value) - minimum >= 2 && maximum - minimum >= 3
  }

  private static func clean(
    _ pools: inout [Pool], samples: [OxygenQualityQueue.Sample], limit: Int64
  ) {
    for index in pools.indices {
      while pools[index].start + 1 < pools[index].end {
        let start = pools[index].start
        var last = start
        while last < pools[index].end, samples[last + 1].value == samples[start].value { last += 1 }
        if samples[last].time - samples[start].time < limit { break }
        pools[index].start += 1
      }
      while pools[index].end - 1 > pools[index].start {
        let end = pools[index].end
        var first = end
        while first > pools[index].start, samples[first - 1].value == samples[end].value {
          first -= 1
        }
        if samples[end].time - samples[first].time < limit { break }
        pools[index].end -= 1
      }
    }
  }
}
