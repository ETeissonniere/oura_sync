import SwiftUI

struct LiveHeartRateView: View {
  let session: LiveHeartRateSession
  let syncing: Bool
  let start: () -> Void
  let stop: () -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 24) {
          Text("Wear your ring and keep your hand still.")
            .font(.subheadline).foregroundStyle(Color.secondaryInk)
          TimelineView(.periodic(from: .now, by: 1)) { context in
            let age = session.receivedAt.map { max(0, Int(context.date.timeIntervalSince($0))) }
            VStack(spacing: 8) {
              Text(
                session.latest.map {
                  $0.beatsPerMinute.formatted(.number.precision(.fractionLength(0)))
                } ?? "—"
              )
              .font(.system(size: 72, weight: .light, design: .rounded))
              .monospacedDigit()
              Text("bpm").foregroundStyle(Color.secondaryInk)
              Text(session.status).font(.headline)
              if let age {
                Text(
                  age == 0
                    ? "Updated just now"
                    : age == 1 ? "Last reading · 1 second ago" : "Last reading · \(age) seconds ago"
                )
                .font(.caption).foregroundStyle(Color.secondaryInk)
                if session.running, age > 10 {
                  Text("Waiting for a fresh reading")
                    .font(.caption).foregroundStyle(Color.secondaryInk)
                }
              }
            }
            .frame(maxWidth: .infinity).padding(.vertical, 20)
            .accessibilityElement(children: .combine)
          }
          if let error = session.error {
            Text(error).font(.subheadline).foregroundStyle(Color.secondaryInk)
          }
          Button(
            session.stopping
              ? "Finishing…" : session.running ? "Stop measurement" : "Start measurement"
          ) {
            if session.running {
              stop()
            } else {
              start()
            }
          }
          .buttonStyle(PrimaryButtonStyle())
          .disabled(session.stopping || (syncing && !session.running))
          if syncing && !session.running {
            Text("Your ring is syncing. You can start when it finishes.")
              .font(.caption).foregroundStyle(Color.secondaryInk)
          }
          Text("Runs for up to 60 seconds. Readings aren’t saved or added to Apple Health.")
            .font(.caption).foregroundStyle(Color.secondaryInk)
        }
        .padding(24)
      }
      .background(Color.paper).foregroundStyle(Color.ink)
      .navigationTitle("Live heart rate").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
      }
    }
    .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    .onDisappear { stop() }
  }
}
