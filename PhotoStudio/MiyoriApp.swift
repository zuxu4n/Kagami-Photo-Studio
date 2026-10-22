import SwiftUI

@main
struct MiyoriApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .tint(.pinkInk)
                .preferredColorScheme(.light)   // one look, whatever the phone is set to
        }
    }
}
