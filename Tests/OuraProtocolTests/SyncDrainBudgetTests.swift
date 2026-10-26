import Foundation
import Testing

@testable import OuraProtocol

@Test func foregroundHistoryDrainContinuesBeyondTwentyFiveSeconds() {
  var budget = SyncDrainBudget()
  for uptime in [0.0, 25, 60, 600, 3_600] {
    let permitted1 = budget.permitsNextBatch(uptime: uptime, foreground: true, cancelled: false)
    #expect(permitted1)
  }
  let permitted2 = !budget.permitsNextBatch(uptime: 3_601, foreground: true, cancelled: true)
  #expect(permitted2)
}

@Test func backgroundHistoryDrainStopsAtBudgetAndForegroundCanResume() {
  var budget = SyncDrainBudget()
  let permitted3 = budget.permitsNextBatch(uptime: 100, foreground: false, cancelled: false)
  #expect(permitted3)
  let permitted4 = budget.permitsNextBatch(uptime: 124, foreground: false, cancelled: false)
  #expect(permitted4)
  let permitted5 = !budget.permitsNextBatch(uptime: 125, foreground: false, cancelled: false)
  #expect(permitted5)
  let permitted6 = budget.permitsNextBatch(uptime: 126, foreground: true, cancelled: false)
  #expect(permitted6)
  let permitted7 = budget.permitsNextBatch(uptime: 200, foreground: false, cancelled: false)
  #expect(permitted7)
  let permitted8 = !budget.permitsNextBatch(uptime: 225, foreground: false, cancelled: false)
  #expect(permitted8)
}

@Test func longForegroundTransferGetsBoundedTimeWhenAppLeavesForeground() {
  var budget = SyncDrainBudget()
  let permitted9 = budget.permitsNextBatch(uptime: 0, foreground: true, cancelled: false)
  #expect(permitted9)
  let permitted10 = budget.permitsNextBatch(uptime: 600, foreground: false, cancelled: false)
  #expect(permitted10)
  let permitted11 = !budget.permitsNextBatch(uptime: 625, foreground: false, cancelled: false)
  #expect(permitted11)
  let permitted12 = !budget.permitsNextBatch(uptime: 626, foreground: true, cancelled: true)
  #expect(permitted12)
}

@Test func historyEvidenceDistinguishesActualBackgroundSavesFromForegroundCompletion() throws {
  var progress = HistorySyncProgress()
  let date = Date(timeIntervalSince1970: 1_790_000_000)
  progress.saved(events: 32, at: date, inBackground: true)
  progress.saved(events: 16, at: date.addingTimeInterval(1), inBackground: true)
  progress.saved(events: 5, at: date.addingTimeInterval(2), inBackground: false)
  progress.finish(.upToDate)
  let restored = try JSONDecoder().decode(
    HistorySyncProgress.self, from: JSONEncoder().encode(progress))
  #expect(restored.background?.events == 48)
  #expect(restored.background?.outcome == .saved)
  #expect(restored.background?.date == date.addingTimeInterval(1))
  #expect(restored.foreground?.events == 5)
  #expect(restored.foreground?.outcome == .upToDate)
  #expect(restored.foreground?.date == date.addingTimeInterval(2))
}

@Test func emptyHistoryChecksDoNotClaimTransferredEventsOrReplaceCommitTime() {
  var progress = HistorySyncProgress()
  let date = Date(timeIntervalSince1970: 1_790_000_000)
  progress.saved(events: 0, at: date, inBackground: true)
  progress.finish(.upToDate)
  #expect(progress.background == nil)
  progress.saved(events: 32, at: date, inBackground: true)
  progress.saved(events: 0, at: date.addingTimeInterval(10), inBackground: true)
  progress.finish(.upToDate)
  #expect(progress.background?.events == 32)
  #expect(progress.background?.date == date)
}

@Test func cancelledHistoryRunPreservesSavedCountWithoutClaimingBackgroundSuccess() {
  var progress = HistorySyncProgress()
  progress.finish(.failed)
  #expect(progress.background == nil)
  #expect(progress.foreground == nil)
  progress.saved(events: 100, at: .now, inBackground: true)
  progress.finish(.interrupted)
  #expect(progress.background?.events == 100)
  #expect(progress.background?.outcome == .interrupted)
  #expect(progress.foreground == nil)
}
