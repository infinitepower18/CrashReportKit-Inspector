import Foundation

nonisolated struct InspectionResult: Codable, Hashable, Identifiable {
    let id: UUID
    let summary: CrashSummary
    let symbolicatedJSON: String

    init(id: UUID = UUID(), summary: CrashSummary, symbolicatedJSON: String) {
        self.id = id
        self.summary = summary
        self.symbolicatedJSON = symbolicatedJSON
    }
}

nonisolated struct CrashSummary: Codable, Hashable {
    let title: String
    let subtitle: String
    let details: [SummaryDetail]
    let frames: [String]
    let notes: [String]
}

nonisolated struct SummaryDetail: Codable, Hashable, Identifiable {
    var id: String { label }
    let label: String
    let value: String
}

nonisolated enum InspectorError: LocalizedError {
    case invalidReport
    case invalidDSYM
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidReport: "The selected file is not a valid CrashReportKit JSON report."
        case .invalidDSYM: "The selected bundle does not contain any DWARF symbol files."
        case .commandFailed(let message): message
        }
    }
}

nonisolated enum CrashReportInspector {
    static func inspect(reportURL: URL, dSYMURL: URL) throws -> InspectionResult {
        let data = try Data(contentsOf: reportURL)
        guard var report = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              report["formatVersion"] != nil,
              report["threads"] is [[String: Any]] else {
            throw InspectorError.invalidReport
        }

        let symbols = try symbols(in: dSYMURL)
        let symbolication = symbolicate(report: &report, symbols: symbols)
        report["offlineSymbolication"] = [
            "dSYM": dSYMURL.lastPathComponent,
            "matchedImages": symbolication.matchedImages,
            "symbolicatedFrames": symbolication.symbolicatedFrames
        ]

        let output = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        guard let json = String(data: output, encoding: .utf8) else { throw InspectorError.invalidReport }

        return InspectionResult(
            summary: summary(from: report, symbolication: symbolication),
            symbolicatedJSON: json
        )
    }

    private struct SymbolFile {
        let url: URL
        let architecture: String
        let uuid: String
    }

    private struct SymbolicationStats {
        var matchedImages = 0
        var symbolicatedFrames = 0
    }

    private static func symbols(in dSYMURL: URL) throws -> [String: SymbolFile] {
        let dwarfDirectory = dSYMURL.appendingPathComponent("Contents/Resources/DWARF", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dwarfDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ), !files.isEmpty else { throw InspectorError.invalidDSYM }

        var result: [String: SymbolFile] = [:]
        for file in files {
            let output = try run("/usr/bin/dwarfdump", arguments: ["--uuid", file.path])
            for line in output.split(separator: "\n") {
                let parts = line.split(separator: " ")
                guard parts.count >= 3, parts[0] == "UUID:" else { continue }
                let uuid = String(parts[1]).uppercased()
                let architecture = String(parts[2]).trimmingCharacters(in: CharacterSet(charactersIn: "()"))
                result[uuid] = SymbolFile(url: file, architecture: architecture, uuid: uuid)
            }
        }
        guard !result.isEmpty else { throw InspectorError.invalidDSYM }
        return result
    }

    private static func symbolicate(
        report: inout [String: Any],
        symbols: [String: SymbolFile]
    ) -> SymbolicationStats {
        guard var threads = report["threads"] as? [[String: Any]] else { return .init() }
        var stats = SymbolicationStats()
        var matchedUUIDs = Set<String>()

        for threadIndex in threads.indices {
            guard var frames = threads[threadIndex]["frames"] as? [[String: Any]] else { continue }
            for frameIndex in frames.indices {
                guard let address = uint64(frames[frameIndex]["address"]),
                      let image = frames[frameIndex]["image"] as? [String: Any],
                      let uuid = (image["uuid"] as? String)?.uppercased(),
                      let offset = uint64(image["offset"]),
                      let symbolFile = symbols[uuid],
                      address >= offset else { continue }

                matchedUUIDs.insert(symbolFile.uuid)
                let loadAddress = address - offset
                if let symbol = try? run(
                    "/usr/bin/atos",
                    arguments: [
                        "-arch", symbolFile.architecture,
                        "-o", symbolFile.url.path,
                        "-l", hexadecimal(loadAddress),
                        hexadecimal(address)
                    ]
                ).trimmingCharacters(in: .whitespacesAndNewlines),
                   !symbol.isEmpty,
                   !symbol.hasPrefix("0x") {
                    frames[frameIndex]["offlineSymbol"] = symbol
                    stats.symbolicatedFrames += 1
                }
            }
            threads[threadIndex]["frames"] = frames
        }
        stats.matchedImages = matchedUUIDs.count
        report["threads"] = threads
        return stats
    }

    private static func summary(
        from report: [String: Any],
        symbolication: SymbolicationStats
    ) -> CrashSummary {
        let process = report["process"] as? [String: Any] ?? [:]
        let exception = report["exception"] as? [String: Any] ?? [:]
        let threads = report["threads"] as? [[String: Any]] ?? []
        let faultingIndex = integer(report["faultingThread"])
        let faultingThread = faultingIndex.flatMap { index in
            threads.first { integer($0["index"]) == index }
        } ?? threads.first { ($0["crashed"] as? Bool) == true }
        let frames = (faultingThread?["frames"] as? [[String: Any]] ?? []).prefix(12).map(frameDescription)

        let appName = process["name"] as? String ?? "Crash Report"
        let version = process["version"] as? String
        let build = process["build"] as? String
        let versionText = [version.map { "Version \($0)" }, build.map { "Build \($0)" }]
            .compactMap { $0 }.joined(separator: " • ")

        var details = [
            SummaryDetail(label: "Exception", value: exception["type"] as? String ?? "Unknown"),
            SummaryDetail(label: "Exception codes", value: exceptionCodes(exception)),
            SummaryDetail(label: "Captured", value: report["capturedAt"] as? String ?? "Unknown"),
            SummaryDetail(label: "Operating system", value: process["operatingSystem"] as? String ?? "Unknown"),
            SummaryDetail(label: "Device", value: process["deviceModel"] as? String ?? "Unknown"),
            SummaryDetail(label: "Threads", value: String(threads.count)),
            SummaryDetail(label: "Faulting thread", value: faultingIndex.map(String.init) ?? "Not identified"),
            SummaryDetail(label: "Offline symbols", value: "\(symbolication.symbolicatedFrames) frames")
        ]
        if let identifier = process["bundleIdentifier"] as? String {
            details.insert(SummaryDetail(label: "Bundle identifier", value: identifier), at: 0)
        }

        var notes: [String] = []
        if symbolication.matchedImages == 0 {
            notes.append("The selected dSYM did not match any binary-image UUID in this report.")
        } else if symbolication.symbolicatedFrames == 0 {
            notes.append("A matching dSYM was found, but no additional frames could be symbolicated.")
        }
        if faultingIndex == nil {
            notes.append("CrashReportKit could not confidently identify a faulting thread.")
        }

        return CrashSummary(
            title: appName,
            subtitle: versionText.isEmpty ? "CrashReportKit report" : versionText,
            details: details,
            frames: frames,
            notes: notes
        )
    }

    private static func frameDescription(_ frame: [String: Any]) -> String {
        let image = frame["image"] as? [String: Any]
        let imageName = image?["name"] as? String ?? "Unknown image"
        let address = uint64(frame["address"]).map(hexadecimal) ?? "Unknown address"
        if let offline = frame["offlineSymbol"] as? String { return "\(imageName)  \(offline)" }
        if let symbols = frame["symbols"] as? [[String: Any]],
           let symbol = symbols.first?["symbol"] as? String {
            return "\(imageName)  \(symbol)"
        }
        return "\(imageName)  \(address)"
    }

    private static func exceptionCodes(_ exception: [String: Any]) -> String {
        if let codes = exception["hexadecimalCodes"] as? [String], !codes.isEmpty {
            return codes.joined(separator: ", ")
        }
        if let codes = exception["codes"] as? [NSNumber], !codes.isEmpty {
            return codes.map { hexadecimal($0.uint64Value) }.joined(separator: ", ")
        }
        return "None"
    }

    private static func uint64(_ value: Any?) -> UInt64? {
        if let number = value as? NSNumber { return number.uint64Value }
        if let string = value as? String {
            return string.hasPrefix("0x")
                ? UInt64(string.dropFirst(2), radix: 16)
                : UInt64(string)
        }
        return nil
    }

    private static func integer(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue ?? (value as? String).flatMap(Int.init)
    }

    private static func hexadecimal(_ value: UInt64) -> String {
        String(format: "0x%016llx", value)
    }

    private static func run(_ executable: String, arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()

        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8) ?? "Symbolication command failed."
            throw InspectorError.commandFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return String(data: outputData, encoding: .utf8) ?? ""
    }
}
