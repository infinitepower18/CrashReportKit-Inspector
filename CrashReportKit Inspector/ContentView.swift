import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.openWindow) private var openWindow
    @State private var reportPath = ""
    @State private var dSYMPath = ""
    @State private var isInspecting = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Inspect a Crash Report")
                    .font(.largeTitle.bold())
                Text("Choose a CrashReportKit JSON report and its matching dSYM.")
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 14) {
                FileInput(
                    title: "Crash report",
                    prompt: "Select a JSON report",
                    path: $reportPath,
                    action: browseForReport
                )
                FileInput(
                    title: "dSYM",
                    prompt: "Select a dSYM bundle",
                    path: $dSYMPath,
                    action: browseForDSYM
                )
            }

            HStack {
                Spacer()
                Button("Inspect", systemImage: "magnifyingglass") {
                    inspect()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(reportPath.isEmpty || dSYMPath.isEmpty || isInspecting)
            }
        }
        .padding(28)
        .frame(width: 560, height: 260)
        .overlay {
            if isInspecting {
                ZStack {
                    Color.black.opacity(0.08)
                    ProgressView("Symbolicating…")
                        .padding(20)
                        .background(.regularMaterial, in: .rect(cornerRadius: 12))
                }
            }
        }
        .alert("Unable to Inspect Report", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }

    private func browseForReport() {
        let panel = NSOpenPanel()
        panel.title = "Choose a CrashReportKit Report"
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            reportPath = url.path
        }
    }

    private func browseForDSYM() {
        let panel = NSOpenPanel()
        panel.title = "Choose a dSYM Bundle"
        panel.allowedContentTypes = [UTType(filenameExtension: "dSYM") ?? .bundle]
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            dSYMPath = url.path
        }
    }

    private func inspect() {
        isInspecting = true
        let reportURL = URL(fileURLWithPath: reportPath)
        let dSYMURL = URL(fileURLWithPath: dSYMPath)

        Task {
            do {
                let result = try await Task.detached {
                    try CrashReportInspector.inspect(reportURL: reportURL, dSYMURL: dSYMURL)
                }.value
                isInspecting = false
                openWindow(value: result)
            } catch {
                isInspecting = false
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct FileInput: View {
    let title: String
    let prompt: String
    @Binding var path: String
    let action: () -> Void

    var body: some View {
        HStack {
            Text(title)
                .frame(width: 90, alignment: .trailing)
            TextField(prompt, text: $path)
                .textFieldStyle(.roundedBorder)
            Button("Browse…", action: action)
        }
    }
}

struct ReportView: View {
    let result: InspectionResult

    var body: some View {
        TabView {
            SummaryView(summary: result.summary)
                .tabItem { Label("Summary", systemImage: "list.bullet.rectangle") }
            RawJSONView(json: result.symbolicatedJSON)
                .tabItem { Label("Raw JSON", systemImage: "curlybraces") }
        }
        .padding()
        .navigationTitle(result.summary.title)
    }
}

private struct SummaryView: View {
    let summary: CrashSummary

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(summary.title).font(.largeTitle.bold())
                    Text(summary.subtitle).foregroundStyle(.secondary)
                }

                GroupBox("Important Details") {
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                        ForEach(summary.details) { detail in
                            GridRow {
                                Text(detail.label).foregroundStyle(.secondary)
                                Text(detail.value).textSelection(.enabled)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                GroupBox("Suspected Crashing Thread") {
                    VStack(alignment: .leading, spacing: 10) {
                        if summary.frames.isEmpty {
                            Text("No stack frames were available.").foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(summary.frames.enumerated()), id: \.offset) { index, frame in
                                HStack(alignment: .firstTextBaseline) {
                                    Text("\(index)").foregroundStyle(.tertiary).monospacedDigit()
                                    Text(frame).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                if !summary.notes.isEmpty {
                    GroupBox("Notes") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(summary.notes, id: \.self) { note in
                                Label(note, systemImage: "info.circle")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                    }
                }
            }
            .padding()
        }
    }
}

private struct RawJSONView: View {
    let json: String

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Text(json)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(.rect(cornerRadius: 8))
    }
}

#Preview {
    ContentView()
}
