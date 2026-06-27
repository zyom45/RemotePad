import SwiftUI

@main
struct RemotePadApp: App {
    @StateObject private var model = RemotePadModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
    }
}
