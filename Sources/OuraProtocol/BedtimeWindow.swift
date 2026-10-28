struct BedtimeWindow {
  let identityStart: Int64
  let supersededStarts: [Int64]
  let start: Int64
  let end: Int64

  /// Call with one clock session. Revisions must share a common interval; a broad
  /// older analysis must not bridge otherwise disjoint naps into one episode.
  static func latest(in events: [RingEvent]) -> [Self] {
    struct Revision {
      let timestamp: UInt32
      let start: Int64
      let end: Int64
    }
    let revisions = events.compactMap { event -> Revision? in
      guard event.tag == 0x76, event.body.count >= 8 else { return nil }
      let bytes = Array(event.body)
      let start = Int64(bytes.uint32(at: 0))
      let end = Int64(bytes.uint32(at: 4))
      guard end > start, end - start <= 864_000 else { return nil }
      return Revision(timestamp: event.timestamp, start: start, end: end)
    }.sorted {
      if $0.start != $1.start { return $0.start < $1.start }
      if $0.end != $1.end { return $0.end < $1.end }
      return $0.timestamp < $1.timestamp
    }
    var families: [[Revision]] = []
    var familyEnd: Int64 = 0
    for revision in revisions {
      if !families.isEmpty, revision.start < familyEnd {
        families[families.count - 1].append(revision)
        familyEnd = min(familyEnd, revision.end)
      } else {
        families.append([revision])
        familyEnd = revision.end
      }
    }
    let windows: [Self] = families.compactMap { family in
      guard
        let first = family.min(by: {
          $0.timestamp == $1.timestamp ? $0.start < $1.start : $0.timestamp < $1.timestamp
        }), let timestamp = family.map(\.timestamp).max(),
        let latest = family.first(where: { $0.timestamp == timestamp }),
        family.filter({ $0.timestamp == timestamp }).allSatisfy({
          $0.start == latest.start && $0.end == latest.end
        })
      else { return nil }
      return Self(
        identityStart: first.start,
        supersededStarts: Set(family.map(\.start)).filter { $0 != first.start }.sorted(),
        start: latest.start, end: latest.end)
    }
    // A chain can leave competing latest windows in separate families. Neither
    // establishes a unique episode, so withhold both rather than export overlaps.
    return windows.enumerated().compactMap { index, window in
      guard
        !windows.enumerated().contains(where: { otherIndex, other in
          index != otherIndex && window.start < other.end && other.start < window.end
        })
      else { return nil }
      return window
    }
  }
}
