import Foundation

/// Bridge to macOS `/usr/bin/textutil` for high-quality text document conversion.
/// Supports: txt, rtf, rtfd, html, doc, docx, odt, wordml, webarchive.
public actor TextUtilService {
    public static let supported: Set<DocumentFormat> = [
        .txt, .rtf, .rtfd, .html, .doc, .docx, .odt, .webarchive
    ]

    public init() {}

    public func isAvailable() -> Bool {
        FileManager.default.isExecutableFile(atPath: "/usr/bin/textutil")
    }

    public func convert(url: URL, to target: DocumentFormat, outputURL: URL) throws -> ProcessingResult {
        guard Self.supported.contains(target) || target == .txt else {
            throw DocuForgeError.unsupportedFormat(target)
        }
        let fmt = textUtilFormat(for: target)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        process.arguments = [
            "-convert", fmt,
            "-output", outputURL.path,
            url.path
        ]
        let err = Pipe()
        process.standardError = err
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: outputURL.path) else {
            let msg = String(data: errData, encoding: .utf8) ?? "textutil failed"
            throw DocuForgeError.conversionFailed(msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return ProcessingResult(
            outputURLs: [outputURL],
            bytesIn: FileIO.fileSize(at: url),
            bytesOut: FileIO.fileSize(at: outputURL),
            notes: ["Converted with macOS textutil (\(fmt))."]
        )
    }

    private func textUtilFormat(for format: DocumentFormat) -> String {
        switch format {
        case .txt: return "txt"
        case .rtf: return "rtf"
        case .rtfd: return "rtfd"
        case .html: return "html"
        case .doc: return "doc"
        case .docx: return "docx"
        case .odt: return "odt"
        case .webarchive: return "webarchive"
        default: return "txt"
        }
    }
}
