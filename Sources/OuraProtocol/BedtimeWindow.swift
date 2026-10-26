struct BedtimeWindow {
  let start: Int64
  let end: Int64

  /// Call with one clock session. A later firmware revision replaces the same start.
  static func latest(in events: [RingEvent]) -> [Self] {
    var revisions: [Int64: (timestamp: UInt32, end: Int64?)] = [:]
    for event in events where event.tag == 0x76 && event.body.count >= 8 {
      let bytes = Array(event.body)
      let start = Int64(bytes.uint32(at: 0))
      let end = Int64(bytes.uint32(at: 4))
      guard end > start, end - start <= 864_000 else { continue }
      if let previous = revisions[start] {
        if event.timestamp < previous.timestamp { continue }
        if event.timestamp == previous.timestamp {
          if previous.end != end { revisions[start] = (event.timestamp, nil) }
          continue
        }
      }
      revisions[start] = (event.timestamp, end)
    }
    return revisions.keys.sorted().compactMap { start in
      guard let end = revisions[start]?.end else { return nil }
      return Self(start: start, end: end)
    }
  }
}
