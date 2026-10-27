import CryptoKit
import Foundation

public enum SleepStage: String, Codable, CaseIterable, Sendable {
  case deep, light, rem, awake
}

public struct SleepStageEpoch: Identifiable, Equatable, Sendable {
  public let id: String
  public let stage: SleepStage
  public let start: Date
  public let end: Date
}

public struct SleepStagePeriod: Identifiable, Equatable, Sendable {
  public enum Timing: String, Sendable {
    case estimatedFromAnalysisCompletion
    case corroboratedBySleepSummary
  }

  public let id: String
  public let session: UUID
  public let start: Date
  public let end: Date
  public let epochs: [SleepStageEpoch]
  public let recordedBedtime: DateInterval?
  // Summary agreement improves display timing; it does not validate the stage
  // classifier or establish that these stages are safe to export to Health.
  public let timing: Timing
}

public struct SleepStages: Sendable {
  public let periods: [SleepStagePeriod]
  public let rejectedRuns: Int
  public let undatedRuns: Int

  /// Decode events from a single ring clock session; counters cannot be compared across resets.
  public init(events: [RingEvent], session: UUID, now: Date = .now) {
    let anchors = events.filter { $0.tag == 0x42 && $0.body.count >= 4 }
      .compactMap { event -> (counter: Int64, unix: TimeInterval)? in
        let unix = TimeInterval(Array(event.body).uint32(at: 0))
        guard unix >= 1_577_836_800, unix <= now.timeIntervalSince1970 else { return nil }
        return (Int64(event.timestamp), unix)
      }.sorted { $0.counter < $1.counter }
    let bedtimes = BedtimeWindow.latest(in: events)
    let summaries = Set(events.filter { $0.tag == 0x49 })
    var runs: [[RingEvent]] = []
    var seen = Set<RingEvent>()
    let pages = events.enumerated().filter { $0.element.tag == 0x5a }.sorted {
      if $0.element.timestamp == $1.element.timestamp { return $0.offset < $1.offset }
      return $0.element.timestamp < $1.element.timestamp
    }
    for (_, page) in pages where seen.insert(page).inserted {
      if page.body.first == 0 || runs.isEmpty {
        runs.append([page])
      } else {
        runs[runs.count - 1].append(page)
      }
    }

    var result: [SleepStagePeriod] = []
    let runCounts = Dictionary(grouping: runs.compactMap { $0.first?.timestamp }, by: { $0 })
      .mapValues(\.count)
    var rejected = 0
    var undated = 0
    for run in runs {
      guard let first = run.first, let last = run.last,
        runCounts[first.timestamp] == 1,
        run.enumerated().allSatisfy({
          $0.element.body.count == 14 && Int($0.element.body.first ?? 255) == $0.offset
        })
      else {
        rejected += 1
        continue
      }
      // Horizon pages carry 52 thirty-second epochs, with MSB-first two-bit
      // codes. Their event timestamps mark analysis output, not epoch times.
      let stageCount = run.count * 52
      var endCounter = Int64(last.timestamp)
      var startCounter = endCounter - Int64(stageCount) * 300
      var corroboratingBedtime: BedtimeWindow?
      // A nearby summary must be unique before inspecting its coverage: picking
      // whichever competing summary fits would hide an ambiguous association.
      let nearbySummaries = summaries.filter {
        Int64($0.timestamp) >= Int64(first.timestamp) - 6_000
          && Int64($0.timestamp) <= Int64(last.timestamp) + 6_000
      }
      if nearbySummaries.count == 1, let summary = nearbySummaries.first,
        summary.body.count == 4
      {
        let bytes = Array(summary.body)
        let startMinutes = Int64(bytes[0]) | (Int64(bytes[1]) << 8)
        let endMinutes = Int64(bytes[2]) | (Int64(bytes[3]) << 8)
        let summaryStart = Int64(summary.timestamp) - startMinutes * 600
        let summaryEnd = Int64(summary.timestamp) - endMinutes * 600
        let matchingBedtimes = bedtimes.filter {
          abs($0.start - summaryStart) <= 600 && abs($0.end - summaryEnd) <= 600
        }
        if summaryStart >= 0, startMinutes > endMinutes,
          summaryEnd - summaryStart == Int64(stageCount) * 300,
          matchingBedtimes.count == 1
        {
          startCounter = summaryStart
          endCounter = summaryEnd
          corroboratingBedtime = matchingBedtimes.first
        }
      }
      // Pages are emitted in an analysis burst. A separation longer than one
      // page's represented duration is conservatively rejected, not a known
      // firmware limit: missing page-zero events could otherwise join nights.
      guard startCounter >= 0, stageCount <= 24 * 60 * 2,
        last.timestamp - first.timestamp <= 52 * 300
      else {
        rejected += 1
        continue
      }
      // Summary offsets are rounded to minutes. Use the bedtime's clock anchor
      // for both windows so a correction between their ends cannot split them.
      let anchorCounter = corroboratingBedtime?.end ?? endCounter
      guard let anchor = anchors.last(where: { $0.counter <= anchorCounter }) ?? anchors.first
      else {
        undated += 1
        continue
      }
      // One anchor dates the entire run; clock corrections cannot stretch epochs.
      func date(_ counter: Int64) -> Date {
        Date(timeIntervalSince1970: anchor.unix + Double(counter - anchor.counter) / 10)
      }
      let start = date(startCounter)
      let end = date(endCounter)
      guard start.timeIntervalSince1970 >= 1_577_836_800, end <= now, end > start else {
        undated += 1
        continue
      }
      let fingerprint = SHA256.hash(data: first.body).map { String(format: "%02x", $0) }.joined()
      let id =
        corroboratingBedtime.map { "\(session.uuidString).sleep.bed.\($0.start)" }
        ?? "\(session.uuidString).sleep.\(first.timestamp).\(fingerprint)"
      var epochs: [SleepStageEpoch] = []
      let stages: [SleepStage] = [.deep, .light, .rem, .awake]
      for page in run {
        for byte in page.body.dropFirst() {
          for shift in [6, 4, 2, 0] {
            let index = epochs.count
            let epochStart = start.addingTimeInterval(Double(index) * 30)
            epochs.append(
              SleepStageEpoch(
                id: "\(id).\(index)", stage: stages[Int((byte >> shift) & 3)],
                start: epochStart, end: epochStart.addingTimeInterval(30)))
          }
        }
      }
      // Bedtime is an independent interval, not an exact stage anchor. Keep it
      // for comparison without moving or stretching firmware stages to fit it.
      let bedtime = (corroboratingBedtime.map { [$0] } ?? bedtimes)
        .filter { $0.start < endCounter && $0.end > startCounter }
        .max { lhs, rhs in
          min(lhs.end, endCounter) - max(lhs.start, startCounter)
            < min(rhs.end, endCounter) - max(rhs.start, startCounter)
        }.flatMap { window -> DateInterval? in
          // Date bedtime independently of the later stage-analysis output, just
          // as Measurements does. A clock correction may occur between them.
          guard
            let bedtimeAnchor = anchors.last(where: { $0.counter <= window.end })
              ?? anchors.first
          else { return nil }
          let endUnix = bedtimeAnchor.unix + Double(window.end - bedtimeAnchor.counter) / 10
          let startUnix = endUnix - Double(window.end - window.start) / 10
          let end = Date(timeIntervalSince1970: endUnix)
          let start = Date(timeIntervalSince1970: startUnix)
          guard start.timeIntervalSince1970 >= 1_577_836_800, end <= now else { return nil }
          return DateInterval(start: start, end: end)
        }
      // Re-analysis of the same corroborated bedtime replaces its older stages.
      result.removeAll { $0.id == id }
      result.append(
        SleepStagePeriod(
          id: id, session: session, start: start, end: end, epochs: epochs,
          recordedBedtime: bedtime,
          timing: corroboratingBedtime == nil
            ? .estimatedFromAnalysisCompletion : .corroboratedBySleepSummary
        ))
    }
    // A partial re-analysis must not displace a corroborated night while its
    // remaining pages are still arriving.
    let corroboratedBedtimes = result.filter { $0.timing == .corroboratedBySleepSummary }
      .compactMap(\.recordedBedtime)
    periods = result.filter {
      $0.timing == .corroboratedBySleepSummary
        || $0.recordedBedtime.map { !corroboratedBedtimes.contains($0) } ?? true
    }
    rejectedRuns = rejected
    undatedRuns = undated
  }
}
