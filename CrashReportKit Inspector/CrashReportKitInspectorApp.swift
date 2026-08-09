import SwiftUI

@main
struct CrashReportKitInspectorApp: App {
    
    init() {
        NSWindow.allowsAutomaticWindowTabbing = false
    }
    
    var body: some Scene {
        Window("CrashReportKit Inspector", id: "main") {
            ContentView()
        }
        .defaultSize(width: 620, height: 310)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        WindowGroup("Crash Report", for: InspectionResult.self) { result in
            if let result = result.wrappedValue {
                ReportView(result: result)
            } else {
                ContentUnavailableView("Report Unavailable", systemImage: "exclamationmark.triangle")
            }
        }
        .defaultSize(width: 900, height: 680)
    }
}
