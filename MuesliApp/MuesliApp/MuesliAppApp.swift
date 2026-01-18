import SwiftUI

@main
struct MuesliAppApp: App {
    @StateObject private var model = AppModel()

    init() {
        signal(SIGPIPE, SIG_IGN)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 980, minHeight: 640)
        }
    }
}
