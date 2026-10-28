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
    case anchoredToSleepSummary
  }

  public let id: String
  public let session: UUID
  public let start: Date
  public let end: Date
  public let epochs: [SleepStageEpoch]
  public let recordedBedtime: DateInterval?
  // Anchored periods have corroborated, finalized firmware stages and a checked
  // summary window. This establishes their timing, not clinical accuracy.
  public let timing: Timing
  public internal(set) var supersededIDs: [String] = []

  public var unrecordedTail: TimeInterval {
    max(0, end.timeIntervalSince(epochs.last?.end ?? end))
  }
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
    let finalizations = Set(events.filter { $0.tag == 0x4c })
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
    for (runIndex, run) in runs.enumerated() {
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
      var stageCount = run.count * 52
      var endCounter = Int64(last.timestamp)
      var startCounter = endCounter - Int64(stageCount) * 300
      var corroboratingBedtime: BedtimeWindow?
      var summaryClockAnchor: (counter: Int64, unix: TimeInterval)?
      // A nearby summary must be unique before inspecting its coverage: picking
      // whichever competing summary fits would hide an ambiguous association.
      let nearbySummaries = summaries.filter {
        Int64($0.timestamp) >= Int64(first.timestamp) - 6_000
          && $0.timestamp < first.timestamp
      }
      if nearbySummaries.count == 1, let summary = nearbySummaries.first,
        summary.body.count == 4
      {
        let bytes = Array(summary.body)
        let startMinutes = Int64(bytes[0]) | (Int64(bytes[1]) << 8)
        let endMinutes = Int64(bytes[2]) | (Int64(bytes[3]) << 8)
        let summaryStart = Int64(summary.timestamp) - startMinutes * 600
        let summaryEnd = Int64(summary.timestamp) - endMinutes * 600
        let validEpochs = (startMinutes - endMinutes) * 2
        let nextRun = runs.dropFirst(runIndex + 1).first?.first?.timestamp ?? UInt32.max
        let nextSummary =
          summaries.filter { $0.timestamp > summary.timestamp }
          .map(\.timestamp).min() ?? UInt32.max
        let endings = finalizations.filter {
          $0.timestamp > last.timestamp && $0.timestamp < min(nextRun, nextSummary)
            && Int64($0.timestamp) <= Int64(last.timestamp) + 6_000
        }
        let matchingBedtimes = bedtimes.filter {
          abs($0.start - summaryStart) <= 600 && abs($0.end - summaryEnd) <= 600
        }
        let suppliedEpochs = run.count * 52
        let deficit = Int(validEpochs) - suppliedEpochs
        let finalBytes = endings.first.map { Array($0.body) } ?? []
        var counts = [0, 0, 0, 0]
        for page in run {
          for byte in page.body.dropFirst() {
            for shift in [6, 4, 2, 0] { counts[Int((byte >> shift) & 3)] += 1 }
          }
        }
        // The native consumer fills a short final page with awake stages.
        // Keep only recorded epochs instead, after the finalized non-awake
        // totals corroborate the supplied pages. Never infer awake physiology.
        let shortFinalRun =
          deficit > 0 && deficit < 52 && finalBytes.count == 14
          && counts[2] == Int(finalBytes[2]) + Int(finalBytes[3]) * 256
          && counts[1] == Int(finalBytes[4]) + Int(finalBytes[5]) * 256
          && counts[0] == Int(finalBytes[6]) + Int(finalBytes[7]) * 256
        if summaryStart >= 0, startMinutes > endMinutes,
          startMinutes <= 0x7ff, endMinutes <= 0x7ff,
          validEpochs <= 16 * 60 * 2, run.count <= 36,
          (validEpochs + 51) / 52 == Int64(run.count) || shortFinalRun,
          endings.count == 1, endings.first?.body.count == 14,
          matchingBedtimes.count == 1, let window = matchingBedtimes.first,
          let summaryAnchor = anchors.last(where: { $0.counter <= Int64(summary.timestamp) })
            ?? anchors.first,
          let bedtimeAnchor = anchors.last(where: { $0.counter <= window.end }) ?? anchors.first,
          abs(
            summaryAnchor.unix + Double(summaryStart - summaryAnchor.counter) / 10
              - bedtimeAnchor.unix - Double(window.start - bedtimeAnchor.counter) / 10) <= 60,
          abs(
            summaryAnchor.unix + Double(summaryEnd - summaryAnchor.counter) / 10
              - bedtimeAnchor.unix - Double(window.end - bedtimeAnchor.counter) / 10) <= 60
        {
          // Oura 7.15 native sleepinfo consumer: 0x11290c anchors at summary
          // start; 0x112c9c divides duration by 30; 0x113488 truncates by count.
          // libappecore SHA-256: 0fefc6a53b2ec9a09ce4081ff3a91807f29b7af788aab1a8885f8f8cdc8548e9.
          // Unused final-page slots are ignored regardless of their stage code.
          stageCount = min(Int(validEpochs), suppliedEpochs)
          startCounter = summaryStart
          endCounter = summaryEnd
          corroboratingBedtime = window
          summaryClockAnchor = summaryAnchor
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
      // The native consumer subtracts offsets from the summary event's mapped
      // UTC time. Preserve its clock correction only when bedtime still agrees.
      guard
        let anchor = summaryClockAnchor
          ?? anchors.last(where: { $0.counter <= endCounter }) ?? anchors.first
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
        corroboratingBedtime.map { "\(session.uuidString).sleep.bed.\($0.identityStart)" }
        ?? "\(session.uuidString).sleep.\(first.timestamp).\(fingerprint)"
      var epochs: [SleepStageEpoch] = []
      let stages: [SleepStage] = [.deep, .light, .rem, .awake]
      for page in run {
        for byte in page.body.dropFirst() {
          for shift in [6, 4, 2, 0] {
            let index = epochs.count
            guard index < stageCount else { continue }
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
            ? .estimatedFromAnalysisCompletion : .anchoredToSleepSummary,
          supersededIDs: corroboratingBedtime?.supersededStarts.map {
            "\(session.uuidString).sleep.bed.\($0)"
          } ?? []
        ))
    }
    // A partial re-analysis must not displace a corroborated night while its
    // remaining pages are still arriving.
    let corroboratedBedtimes = result.filter { $0.timing == .anchoredToSleepSummary }
      .compactMap(\.recordedBedtime)
    periods = result.filter {
      $0.timing == .anchoredToSleepSummary
        || $0.recordedBedtime.map { !corroboratedBedtimes.contains($0) } ?? true
    }
    rejectedRuns = rejected
    undatedRuns = undated
  }
}
