import Foundation

/// Optional headless LibreOffice bridge for high-fidelity Office conversions when installed.
public actor LibreOfficeService {
    public init() {}

    public func executableURL() -> URL? {
        let candidates = [
            "/Applications/LibreOffice.app/Contents/MacOS/soffice",
            "/opt/homebrew/bin/soffice",
            "/usr/local/bin/soffice",
            "/usr/bin/soffice"
        ]
        return candidates.map { URL(fileURLWithPath: $0) }.first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }

    public var isAvailable: Bool { executableURL() != nil }

    public func convert(url: URL, to target: DocumentFormat, outputDirectory: URL) throws -> ProcessingResult {
        guard let soffice = executableURL() else {
            throw DocuForgeError.conversionFailed(
                "LibreOffice is not installed. Install LibreOffice for high-fidelity conversion of PPT/XLS/ODP/ODS and similar formats."
            )
        }
        let filter = libreFilter(for: target)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = soffice
        process.arguments = [
            "--headless",
            "--nologo",
            "--nolockcheck",
            "--nodefault",
            "--convert-to", filter,
            "--outdir", outputDirectory.path,
            url.path
        ]
        let err = Pipe()
        process.standardError = err
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()

        let base = url.deletingPathExtension().lastPathComponent
        let out = outputDirectory.appendingPathComponent("\(base).\(target.pathExtension)")
        // LibreOffice may use slightly different extensions
        let alt = outputDirectory.appendingPathComponent("\(base).\(filter.split(separator: ":").first.map(String.init) ?? target.pathExtension)")
        let resolved = FileManager.default.fileExists(atPath: out.path) ? out
            : (FileManager.default.fileExists(atPath: alt.path) ? alt : nil)

        guard process.terminationStatus == 0, let resolved else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "LibreOffice failed"
            throw DocuForgeError.conversionFailed(msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return ProcessingResult(
            outputURLs: [resolved],
            bytesIn: FileIO.fileSize(at: url),
            bytesOut: FileIO.fileSize(at: resolved),
            notes: ["Converted with LibreOffice (\(filter))."]
        )
    }

    private func libreFilter(for target: DocumentFormat) -> String {
        switch target {
        case .pdf: return "pdf"
        case .docx: return "docx"
        case .doc: return "doc"
        case .odt: return "odt"
        case .rtf: return "rtf"
        case .txt: return "txt:Text"
        case .html: return "html"
        case .pptx: return "pptx"
        case .ppt: return "ppt"
        case .odp: return "odp"
        case .xlsx: return "xlsx"
        case .xls: return "xls"
        case .ods: return "ods"
        case .csv: return "csv"
        case .png: return "png"
        case .epub: return "epub"
        default: return target.pathExtension
        }
    }
}
