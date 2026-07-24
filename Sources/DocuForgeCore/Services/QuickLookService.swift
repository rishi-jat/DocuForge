import Foundation
import AppKit

/// Uses `qlmanage` to generate preview thumbnails when no better converter exists.
public actor QuickLookService {
    public init() {}

    public func isAvailable() -> Bool {
        FileManager.default.isExecutableFile(atPath: "/usr/bin/qlmanage")
    }

    /// Generate a PNG preview thumbnail for any file Quick Look understands.
    public func thumbnail(url: URL, outputDirectory: URL, maxSize: Int = 2048) throws -> ProcessingResult {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        process.arguments = [
            "-t",
            "-s", "\(maxSize)",
            "-o", outputDirectory.path,
            url.path
        ]
        let err = Pipe()
        process.standardError = err
        process.standardOutput = Pipe()
        try process.run()
        // qlmanage can hang on exotic/incomplete packages — bound the wait.
        let deadline = Date().addingTimeInterval(20)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if process.isRunning {
            process.terminate()
            throw DocuForgeError.conversionFailed("Quick Look timed out generating a preview for \(url.lastPathComponent).")
        }

        // qlmanage names output like "file.ext.png"
        let expected = outputDirectory.appendingPathComponent(url.lastPathComponent + ".png")
        let contents = (try? FileManager.default.contentsOfDirectory(at: outputDirectory, includingPropertiesForKeys: nil)) ?? []
        let pngs = contents.filter { $0.pathExtension.lowercased() == "png" }
        let out = FileManager.default.fileExists(atPath: expected.path) ? expected : pngs.first

        guard let out else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw DocuForgeError.conversionFailed(
                "Quick Look could not generate a preview.\(msg.isEmpty ? "" : " \(msg)")"
            )
        }
        return ProcessingResult(
            outputURLs: [out],
            bytesIn: FileIO.fileSize(at: url),
            bytesOut: FileIO.fileSize(at: out),
            notes: ["Generated via Quick Look thumbnail (preview quality, not multi-page)."]
        )
    }
}
