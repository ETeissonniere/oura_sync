import SwiftUI

@main
struct OuraSyncApp: App {
  @UIApplicationDelegateAdaptor(BackgroundSync.self) private var delegate
  var body: some Scene {
    WindowGroup { RootView() }
  }
}
