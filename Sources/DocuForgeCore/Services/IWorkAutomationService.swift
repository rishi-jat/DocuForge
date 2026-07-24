import Foundation
import AppKit

/// High-fidelity iWork conversion by automating Pages / Keynote / Numbers when installed.
public actor IWorkAutomationService {
    public enum AppKind: String, Sendable {
        case pages
        case keynote
        case numbers

        var appName: String {
            switch self {
            case .pages: return "Pages"
            case .keynote: return "Keynote"
            case .numbers: return "Numbers"
            }
        }

        var bundleCandidates: [String] {
            switch self {
            case .pages: return ["/Applications/Pages.app", "/System/Applications/Pages.app"]
            case .keynote: return ["/Applications/Keynote.app", "/System/Applications/Keynote.app"]
            case .numbers: return ["/Applications/Numbers.app", "/System/Applications/Numbers.app"]
            }
        }

        static func forFormat(_ format: DocumentFormat) -> AppKind? {
            switch format {
            case .pages: return .pages
            case .key: return .keynote
            case .numbers: return .numbers
            default: return nil
            }
        }
    }

    public init() {}

    public func isInstalled(_ app: AppKind) -> Bool {
        app.bundleCandidates.contains { FileManager.default.fileExists(atPath: $0) }
    }

    public func installedIWorkApps() -> [AppKind] {
        AppKind.allCases.filter { isInstalled($0) }
    }

    /// Export an iWork document to PDF (or other Apple-supported export) via AppleScript.
    public func export(
        url: URL,
        source: DocumentFormat,
        to target: DocumentFormat,
        outputDirectory: URL
    ) throws -> ProcessingResult {
        guard let app = AppKind.forFormat(source) else {
            throw DocuForgeError.invalidInput("Not an iWork format.")
        }
        guard isInstalled(app) else {
            throw DocuForgeError.conversionFailed(
                "\(app.appName) is not installed. Install it from the App Store for high-fidelity export, or provide a file with an embedded QuickLook preview."
            )
        }

        let exportType: String
        let ext: String
        switch (app, target) {
        case (_, .pdf):
            exportType = "PDF"; ext = "pdf"
        case (.pages, .docx):
            exportType = "Microsoft Word"; ext = "docx"
        case (.pages, .odt):
            // Pages scripting uses different labels by version; PDF is most reliable.
            exportType = "PDF"; ext = "pdf"
        case (.pages, .rtf):
            exportType = "RTF"; ext = "rtf"
        case (.pages, .txt):
            exportType = "plain text"; ext = "txt"
        case (.pages, .epub):
            exportType = "EPUB"; ext = "epub"
        case (.keynote, .pptx):
            exportType = "Microsoft PowerPoint"; ext = "pptx"
        case (.keynote, .png):
            exportType = "PDF"; ext = "pdf" // then rasterize later
        case (.numbers, .xlsx):
            exportType = "Microsoft Excel"; ext = "xlsx"
        case (.numbers, .csv):
            exportType = "CSV"; ext = "csv"
        default:
            exportType = "PDF"; ext = "pdf"
        }

        let base = url.deletingPathExtension().lastPathComponent
        let out = outputDirectory.appendingPathComponent("\(base).\(ext)")
        if FileManager.default.fileExists(atPath: out.path) {
            try FileManager.default.removeItem(at: out)
        }

        // Escape paths for AppleScript strings
        let inPath = url.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let outPath = out.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")

        let script: String
        switch app {
        case .pages:
            script = """
            set inFile to POSIX file "\(inPath)"
            set outFile to POSIX file "\(outPath)"
            tell application "Pages"
              activate
              set theDoc to open inFile
              delay 0.5
              try
                export theDoc to outFile as \(appleScriptExportToken(exportType))
              on error errMsg number errNum
                close theDoc saving no
                error errMsg number errNum
              end try
              close theDoc saving no
            end tell
            """
        case .keynote:
            script = """
            set inFile to POSIX file "\(inPath)"
            set outFile to POSIX file "\(outPath)"
            tell application "Keynote"
              activate
              set theDoc to open inFile
              delay 0.5
              try
                export theDoc to outFile as \(appleScriptExportToken(exportType))
              on error errMsg number errNum
                close theDoc saving no
                error errMsg number errNum
              end try
              close theDoc saving no
            end tell
            """
        case .numbers:
            script = """
            set inFile to POSIX file "\(inPath)"
            set outFile to POSIX file "\(outPath)"
            tell application "Numbers"
              activate
              set theDoc to open inFile
              delay 0.5
              try
                export theDoc to outFile as \(appleScriptExportToken(exportType))
              on error errMsg number errNum
                close theDoc saving no
                error errMsg number errNum
              end try
              close theDoc saving no
            end tell
            """
        }

        try runAppleScript(script, timeout: 45)

        // If we fell back to PDF for a non-PDF target, note that
        var notes = ["Exported with \(app.appName) automation (\(exportType))."]
        if target != DocumentFormat.detect(url: out), target != .pdf, ext == "pdf" {
            notes.append("\(app.appName) exported PDF as the most reliable high-fidelity format for this target.")
        }

        guard FileManager.default.fileExists(atPath: out.path) else {
            throw DocuForgeError.conversionFailed(
                "\(app.appName) did not produce an output file. Grant Automation permission for DocuForge in System Settings → Privacy & Security → Automation, then try again."
            )
        }

        // If caller wanted images from Keynote/Pages and we have PDF, leave PDF
        // (ConversionService may re-enter for PDF→image).
        return ProcessingResult(
            outputURLs: [out],
            bytesIn: FileIO.fileSize(at: url),
            bytesOut: FileIO.fileSize(at: out),
            notes: notes
        )
    }

    private func appleScriptExportToken(_ label: String) -> String {
        // Pages/Keynote use unquoted enum-like tokens for some formats and quoted for others.
        switch label {
        case "PDF": return "PDF"
        case "EPUB": return "EPUB"
        case "RTF": return "RTF"
        case "CSV": return "CSV"
        case "plain text": return "plain text"
        case "Microsoft Word": return "Microsoft Word"
        case "Microsoft PowerPoint": return "Microsoft PowerPoint"
        case "Microsoft Excel": return "Microsoft Excel"
        default: return "PDF"
        }
    }

    private func runAppleScript(_ source: String, timeout: TimeInterval) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if process.isRunning {
            process.terminate()
            throw DocuForgeError.conversionFailed("iWork automation timed out after \(Int(timeout))s.")
        }
        guard process.terminationStatus == 0 else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
                ?? "AppleScript failed"
            throw DocuForgeError.conversionFailed(
                msg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "iWork automation failed (status \(process.terminationStatus)). Check Automation permissions."
                    : msg.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }
}

extension IWorkAutomationService.AppKind: CaseIterable {}
