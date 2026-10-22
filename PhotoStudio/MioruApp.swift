import SwiftUI

@main
struct MioruApp: App {
    init() {
        // The six tool names fit across a phone when the short ones (Heal, Face) take less room.
        UISegmentedControl.appearance().apportionsSegmentWidthsByContent = true
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
