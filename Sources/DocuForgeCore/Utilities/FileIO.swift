import Foundation

public enum FileIO: Sendable {
    /// Unique output URL in the system temporary directory.
    public static func temporaryURL(prefix: String, ext: String) -> URL {
        let name = "\(prefix)-\(UUID().uuidString).\(ext)"
        return FileManager.default.temporaryDirectory.appendingPathComponent(name)
    }

    /// Unique output URL next to a source file (or in its parent).
    public static func siblingURL(for source: URL, suffix: String, ext: String) -> URL {
        let base = source.deletingPathExtension().lastPathComponent
        let parent = source.deletingLastPathComponent()
        var candidate = parent.appendingPathComponent("\(base)\(suffix).\(ext)")
        var n = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("\(base)\(suffix)-\(n).\(ext)")
            n += 1
        }
        return candidate
    }

    public static func fileSize(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    public static func ensureParentDirectory(for url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    }

    /// Creates a dedicated output folder inside the user's Downloads for a job.
    public static func downloadsOutputDirectory(named name: String) throws -> URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = downloads.appendingPathComponent("DocuForge/\(name)-\(formattedStamp())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func formattedStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
}
