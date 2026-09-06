import SwiftUI

@main
struct MuesliAppApp: App {
    @NSApplicationDelegateAdaptor(QuitApplicationDelegate.self) private var applicationDelegate
    @StateObject private var model: AppModel
    @StateObject private var quit = ApplicationQuitCoordinator.shared

    init() {
        signal(SIGPIPE, SIG_IGN)
        let model = AppModel()
        _model = StateObject(wrappedValue: model)
        ApplicationQuitCoordinator.shared.configure(accepted: { [weak model] in model?.applicationQuitAccepted() },
                                                    prepare: { [weak model] in await model?.prepareForApplicationQuit() },
                                                    cancelled: { [weak model] in model?.applicationQuitCancelled() })
        model.startArchiveIntegration()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.meters)
                .environmentObject(model.transcriptModel)
                .frame(minWidth: 980, minHeight: 640)
                .disabled(quit.isRequested)
        }
    }
}
