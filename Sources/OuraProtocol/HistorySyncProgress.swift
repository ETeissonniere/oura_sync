import Foundation

public struct HistorySyncProgress: Codable, Sendable {
  public enum Outcome: String, Codable, Sendable {
    case saved, upToDate, interrupted, failed
  }

  public struct Transfer: Codable, Sendable {
    public let date: Date
    public let events: Int
    public let outcome: Outcome
  }

  public var foreground: Transfer?
  public var background: Transfer?
  private var lastWasBackground: Bool?

  public init() {}

  /// Record only after a history batch and its cursor have committed to storage.
  public mutating func saved(events: Int, at date: Date, inBackground: Bool) {
    lastWasBackground = inBackground
    guard events > 0 else { return }
    let previous = inBackground ? background : foreground
    let transfer = Transfer(date: date, events: (previous?.events ?? 0) + events, outcome: .saved)
    if inBackground { background = transfer } else { foreground = transfer }
  }

  public mutating func finish(_ outcome: Outcome) {
    guard let lastWasBackground,
      let previous = lastWasBackground ? background : foreground
    else { return }
    let transfer = Transfer(date: previous.date, events: previous.events, outcome: outcome)
    if lastWasBackground { background = transfer } else { foreground = transfer }
  }
}
