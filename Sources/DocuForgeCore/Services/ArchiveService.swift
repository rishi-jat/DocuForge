import Foundation

/// Archive listing and extraction using system tools.
public actor ArchiveService {
    public init() {}

    public func list(url: URL, format: DocumentFormat) throws -> [String] {
        switch format {
        case .zip:
            return try OfficeOpenXML.zipList(url: url)
        case .tar, .gzip:
            return try runListTar(url: url)
        default:
            throw DocuForgeError.unsupportedFormat(format)
        }
    }

    public func extract(url: URL, format: DocumentFormat, outputDirectory: URL) throws -> ProcessingResult {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        switch format {
        case .zip:
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-o", url.path, "-d", outputDirectory.path]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw DocuForgeError.conversionFailed("Failed to extract ZIP.")
            }
        case .tar, .gzip:
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["-xf", url.path, "-C", outputDirectory.path]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw DocuForgeError.conversionFailed("Failed to extract archive.")
            }
        default:
            throw DocuForgeError.unsupportedFormat(format)
        }

        let files = try FileManager.default.contentsOfDirectory(at: outputDirectory, includingPropertiesForKeys: nil)
        return ProcessingResult(
            outputURLs: files,
            bytesIn: FileIO.fileSize(at: url),
            notes: ["Extracted \(files.count) item(s)."]
        )
    }

    public func createZip(from urls: [URL], outputURL: URL) throws -> ProcessingResult {
        guard !urls.isEmpty else { throw DocuForgeError.invalidInput("Nothing to zip.") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-jr", outputURL.path] + urls.map(\.path)
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw DocuForgeError.conversionFailed("Failed to create ZIP.")
        }
        return ProcessingResult(
            outputURLs: [outputURL],
            bytesOut: FileIO.fileSize(at: outputURL),
            notes: ["Created ZIP archive."]
        )
    }

    private func runListTar(url: URL) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-tf", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.split(whereSeparator: \.isNewline).map(String.init)
    }
}
