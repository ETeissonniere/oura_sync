import CryptoKit
import Foundation
import SQLite3

public actor EventStore {
  public struct Failure: Error, Sendable {
    public let message: String
  }

  // The connection is confined to EventStore's actor. The wrapper also closes it
  // when initialization fails, without a nonisolated actor deinit accessing it.
  private final class Connection: @unchecked Sendable {
    let handle: OpaquePointer
    init(url: URL) throws {
      var handle: OpaquePointer?
      let status = sqlite3_open_v2(
        url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
      guard status == SQLITE_OK, let handle else {
        if let handle { sqlite3_close(handle) }
        throw Failure(message: "Could not open the ring history database.")
      }
      self.handle = handle
    }
    deinit { sqlite3_close(handle) }
  }

  private let connection: Connection

  public init(url: URL) throws {
    let connection = try Connection(url: url)
    self.connection = connection
    let schema = """
      PRAGMA journal_mode=WAL;
      PRAGMA synchronous=FULL;
      CREATE TABLE IF NOT EXISTS events (
        session TEXT NOT NULL, tag INTEGER NOT NULL, timestamp INTEGER NOT NULL,
        body BLOB NOT NULL, UNIQUE(session, tag, timestamp, body)
      );
      CREATE TABLE IF NOT EXISTS checkpoints (
        session TEXT PRIMARY KEY, cursor INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS health_exports (
        id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL,
        version INTEGER NOT NULL, completed INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS health_sleep_exports (
        id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL,
        version INTEGER NOT NULL, completed INTEGER NOT NULL
      );
      """
    guard sqlite3_exec(connection.handle, schema, nil, nil, nil) == SQLITE_OK else {
      throw Failure(message: "Could not initialize the ring history database.")
    }
  }

  public func cursor(session: UUID) throws -> UInt32 {
    let statement = try prepare("SELECT cursor FROM checkpoints WHERE session = ?")
    defer { sqlite3_finalize(statement) }
    try bind(session.uuidString, to: statement, index: 1)
    let result = sqlite3_step(statement)
    if result == SQLITE_DONE { return 0 }
    guard result == SQLITE_ROW, let cursor = UInt32(exactly: sqlite3_column_int64(statement, 0))
    else {
      throw failure()
    }
    return cursor
  }

  // Each reset/onboarding gets a new session UUID because the ring's boot counter
  // can restart. Old measurements remain intact under their original session.
  public func commit(_ batch: HistoryBatch, session: UUID, expectedCursor: UInt32) throws {
    try execute("BEGIN IMMEDIATE")
    do {
      guard batch.requestedCursor == expectedCursor,
        try cursor(session: session) == expectedCursor, batch.nextCursor >= expectedCursor
      else {
        throw Failure(message: "The history checkpoint changed. Retry the sync.")
      }
      let insert = try prepare(
        "INSERT OR IGNORE INTO events(session, tag, timestamp, body) VALUES (?, ?, ?, ?)")
      defer { sqlite3_finalize(insert) }
      for event in batch.events {
        sqlite3_reset(insert)
        sqlite3_clear_bindings(insert)
        try bind(session.uuidString, to: insert, index: 1)
        guard sqlite3_bind_int(insert, 2, Int32(event.tag)) == SQLITE_OK,
          sqlite3_bind_int64(insert, 3, Int64(event.timestamp)) == SQLITE_OK
        else { throw failure() }
        let status = event.body.withUnsafeBytes { bytes in
          if bytes.isEmpty { return sqlite3_bind_zeroblob(insert, 4, 0) }
          return sqlite3_bind_blob(
            insert, 4, bytes.baseAddress, Int32(bytes.count),
            unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard status == SQLITE_OK, sqlite3_step(insert) == SQLITE_DONE else { throw failure() }
      }
      let checkpoint = try prepare(
        "INSERT INTO checkpoints(session, cursor) VALUES (?, ?) ON CONFLICT(session) DO UPDATE SET cursor = excluded.cursor"
      )
      defer { sqlite3_finalize(checkpoint) }
      try bind(session.uuidString, to: checkpoint, index: 1)
      guard sqlite3_bind_int64(checkpoint, 2, Int64(batch.nextCursor)) == SQLITE_OK,
        sqlite3_step(checkpoint) == SQLITE_DONE
      else { throw failure() }
      try execute("COMMIT")
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
  }

  public func events(session: UUID) throws -> [RingEvent] {
    let statement = try prepare(
      "SELECT tag, timestamp, body FROM events WHERE session = ? ORDER BY timestamp, rowid")
    defer { sqlite3_finalize(statement) }
    try bind(session.uuidString, to: statement, index: 1)
    var events: [RingEvent] = []
    while true {
      let result = sqlite3_step(statement)
      if result == SQLITE_DONE { return events }
      guard result == SQLITE_ROW,
        let tag = UInt8(exactly: sqlite3_column_int(statement, 0)),
        let timestamp = UInt32(exactly: sqlite3_column_int64(statement, 1))
      else { throw failure() }
      let count = Int(sqlite3_column_bytes(statement, 2))
      let body: [UInt8]
      if count == 0 {
        body = []
      } else if let pointer = sqlite3_column_blob(statement, 2) {
        body = Array(UnsafeRawBufferPointer(start: pointer, count: count))
      } else {
        throw failure()
      }
      let timestampBytes = (0..<4).map { UInt8(truncatingIfNeeded: timestamp >> ($0 * 8)) }
      events.append(try RingEvent(packet: Packet(tag: tag, payload: timestampBytes + body)))
    }
  }

  public func recordedHistory(now: Date = .now) throws -> (
    measurements: [Measurement], sleepPeriods: [SleepStagePeriod], nightlyVitals: [NightlyVitals],
    undatedEvents: Int
  ) {
    let statement = try prepare("SELECT DISTINCT session FROM events ORDER BY session")
    defer { sqlite3_finalize(statement) }
    var measurements: [Measurement] = []
    var sleepPeriods: [SleepStagePeriod] = []
    var nightlyVitals: [NightlyVitals] = []
    var undatedEvents = 0
    while true {
      try Task.checkCancellation()
      let result = sqlite3_step(statement)
      if result == SQLITE_DONE { break }
      guard result == SQLITE_ROW, let text = sqlite3_column_text(statement, 0),
        let session = UUID(uuidString: String(cString: text))
      else { throw failure() }
      // A reset starts a new counter epoch. Decode each session with its own
      // clock anchors before combining the user's saved history.
      let events = try events(session: session)
      let decoded = Measurements(events: events, session: session, now: now)
      measurements.append(contentsOf: decoded.samples)
      nightlyVitals.append(
        contentsOf: NightlyVitals.calculate(measurements: decoded.samples, session: session))
      sleepPeriods.append(
        contentsOf: SleepStages(events: events, session: session, now: now).periods)
      undatedEvents += decoded.undatedEvents
    }
    measurements.sort { $0.end == $1.end ? $0.id < $1.id : $0.end < $1.end }
    sleepPeriods.sort { $0.end == $1.end ? $0.id < $1.id : $0.end < $1.end }
    nightlyVitals.sort { $0.end == $1.end ? $0.id < $1.id : $0.end < $1.end }
    return (measurements, sleepPeriods, nightlyVitals, undatedEvents)
  }

  public func prepareHealthExports(_ measurements: [Measurement]) throws -> [HealthExportRecord] {
    try execute("BEGIN IMMEDIATE")
    do {
      let lookup = try prepare(
        "SELECT fingerprint, version, completed FROM health_exports WHERE id = ?")
      defer { sqlite3_finalize(lookup) }
      let update = try prepare(
        "INSERT INTO health_exports(id, fingerprint, version, completed) VALUES (?, ?, ?, 0) ON CONFLICT(id) DO UPDATE SET fingerprint = excluded.fingerprint, version = excluded.version, completed = 0"
      )
      defer { sqlite3_finalize(update) }
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      var records: [HealthExportRecord] = []
      for measurement in measurements {
        try Task.checkCancellation()
        let fingerprint = SHA256.hash(data: try encoder.encode(measurement))
          .map { String(format: "%02x", $0) }.joined()
        sqlite3_reset(lookup)
        sqlite3_clear_bindings(lookup)
        try bind(measurement.id, to: lookup, index: 1)
        let result = sqlite3_step(lookup)
        // Version one was used by builds without a journal. Start above it so
        // corrected dates can replace those existing HealthKit samples.
        var version = 2
        if result == SQLITE_ROW {
          guard let text = sqlite3_column_text(lookup, 0),
            let previousVersion = Int(exactly: sqlite3_column_int64(lookup, 1)),
            previousVersion >= 2, previousVersion < Int.max
          else { throw failure() }
          let unchanged = String(cString: text) == fingerprint
          if unchanged && sqlite3_column_int(lookup, 2) == 1 { continue }
          version = unchanged ? previousVersion : previousVersion + 1
        } else if result != SQLITE_DONE {
          throw failure()
        }
        sqlite3_reset(update)
        sqlite3_clear_bindings(update)
        try bind(measurement.id, to: update, index: 1)
        try bind(fingerprint, to: update, index: 2)
        guard sqlite3_bind_int64(update, 3, Int64(version)) == SQLITE_OK,
          sqlite3_step(update) == SQLITE_DONE
        else { throw failure() }
        records.append(HealthExportRecord(measurement: measurement, version: version))
      }
      try execute("COMMIT")
      return records
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
  }

  public func completeHealthExports(_ records: [HealthExportRecord]) throws {
    try execute("BEGIN IMMEDIATE")
    do {
      let update = try prepare(
        "UPDATE health_exports SET completed = 1 WHERE id = ? AND version = ?")
      defer { sqlite3_finalize(update) }
      for record in records {
        try Task.checkCancellation()
        sqlite3_reset(update)
        sqlite3_clear_bindings(update)
        try bind(record.measurement.id, to: update, index: 1)
        guard sqlite3_bind_int64(update, 2, Int64(record.version)) == SQLITE_OK,
          sqlite3_step(update) == SQLITE_DONE
        else { throw failure() }
      }
      try execute("COMMIT")
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
  }

  public func prepareSleepHealthExport(_ period: SleepStagePeriod) throws
    -> SleepHealthExportRecord?
  {
    guard period.timing == .anchoredToSleepSummary else { return nil }
    struct Epoch: Encodable {
      let id: String
      let stage: SleepStage
      let start: Date
      let end: Date
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(
      period.epochs.map {
        Epoch(id: $0.id, stage: $0.stage, start: $0.start, end: $0.end)
      })
    // Cleanup is part of the revision: discovering an obsolete exported identity
    // must trigger a retry even when the retained epochs did not change.
    let cleanup = try encoder.encode(period.supersededIDs.sorted())
    let fingerprintData = period.supersededIDs.isEmpty ? data : data + cleanup
    let fingerprint = SHA256.hash(data: fingerprintData).map { String(format: "%02x", $0) }.joined()
    let lookup = try prepare(
      "SELECT fingerprint, version, completed FROM health_sleep_exports WHERE id = ?")
    defer { sqlite3_finalize(lookup) }
    try bind(period.id, to: lookup, index: 1)
    let result = sqlite3_step(lookup)
    var version = 1
    if result == SQLITE_ROW {
      guard let text = sqlite3_column_text(lookup, 0),
        let previousVersion = Int(exactly: sqlite3_column_int64(lookup, 1)),
        previousVersion > 0, previousVersion < Int.max
      else { throw failure() }
      let unchanged = String(cString: text) == fingerprint
      if unchanged && sqlite3_column_int(lookup, 2) == 1 { return nil }
      version = unchanged ? previousVersion : previousVersion + 1
    } else if result != SQLITE_DONE {
      throw failure()
    }
    let update = try prepare(
      "INSERT INTO health_sleep_exports(id, fingerprint, version, completed) VALUES (?, ?, ?, 0) ON CONFLICT(id) DO UPDATE SET fingerprint = excluded.fingerprint, version = excluded.version, completed = 0"
    )
    defer { sqlite3_finalize(update) }
    try bind(period.id, to: update, index: 1)
    try bind(fingerprint, to: update, index: 2)
    guard sqlite3_bind_int64(update, 3, Int64(version)) == SQLITE_OK,
      sqlite3_step(update) == SQLITE_DONE
    else { throw failure() }
    return SleepHealthExportRecord(period: period, version: version)
  }

  public func completeSleepHealthExport(_ record: SleepHealthExportRecord) throws {
    let statement = try prepare(
      "UPDATE health_sleep_exports SET completed = 1 WHERE id = ? AND version = ?")
    defer { sqlite3_finalize(statement) }
    try bind(record.period.id, to: statement, index: 1)
    guard sqlite3_bind_int64(statement, 2, Int64(record.version)) == SQLITE_OK,
      sqlite3_step(statement) == SQLITE_DONE
    else { throw failure() }
  }

  private func prepare(_ sql: String) throws -> OpaquePointer {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(connection.handle, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else { throw failure() }
    return statement
  }

  private func bind(_ text: String, to statement: OpaquePointer, index: Int32) throws {
    let result = text.withCString {
      sqlite3_bind_text(
        statement, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
    guard result == SQLITE_OK else { throw failure() }
  }

  private func execute(_ sql: String) throws {
    guard sqlite3_exec(connection.handle, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
  }

  private func failure() -> Failure {
    Failure(message: String(cString: sqlite3_errmsg(connection.handle)))
  }
}
