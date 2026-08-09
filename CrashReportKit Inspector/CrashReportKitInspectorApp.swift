import Sparkle
import SwiftUI
import Combine

@main
struct CrashReportKitInspectorApp: App {
    private let updaterController: SPUStandardUpdaterController

    init() {
        NSWindow.allowsAutomaticWindowTabbing = false

        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var body: some Scene {
        Window("CrashReportKit Inspector", id: "main") {
            ContentView()
        }
        .defaultSize(width: 620, height: 310)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}

            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(
                    updater: updaterController.updater
                )
            }
        }

        WindowGroup("Crash Report", for: InspectionResult.self) { result in
            if let result = result.wrappedValue {
                ReportView(result: result)
            } else {
                ContentUnavailableView(
                    "Report Unavailable",
                    systemImage: "exclamationmark.triangle"
                )
            }
        }
        .defaultSize(width: 900, height: 680)
    }
}

private final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

private struct CheckForUpdatesView: View {
    @ObservedObject private var viewModel: CheckForUpdatesViewModel

    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        viewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("Check for Updates…", action: updater.checkForUpdates)
            .disabled(!viewModel.canCheckForUpdates)
    }
}
