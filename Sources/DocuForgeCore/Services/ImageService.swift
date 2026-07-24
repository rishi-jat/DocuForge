import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics
import PDFKit

/// Image format conversion via ImageIO / AppKit, with multi-frame and SVG support.
public actor ImageService {
    /// Default still-image encode quality when a lossy codec is required (near-lossless).
    public static let highEncodeQuality: CGFloat = 0.95

    public init() {}

    public func convert(
        url: URL,
        to format: DocumentFormat,
        outputURL: URL,
        jpegQuality: CGFloat = ImageService.highEncodeQuality
    ) throws -> ProcessingResult {
        guard format.isImage else {
            throw DocuForgeError.invalidInput("Target must be an image format.")
        }
        let frames = try Self.syncLoadAllFrames(url: url)
        guard let first = frames.first else {
            throw DocuForgeError.conversionFailed("Could not load \(url.lastPathComponent)")
        }

        // Multi-frame source → multi-page TIFF when targeting TIFF; otherwise first frame
        // with a note, or multi-file export for other formats is handled by convertAllFrames.
        if frames.count > 1, format == .tiff {
            try writeMultiPageTIFF(frames: frames, to: outputURL)
            return ProcessingResult(
                outputURLs: [outputURL],
                bytesIn: FileIO.fileSize(at: url),
                bytesOut: FileIO.fileSize(at: outputURL),
                notes: ["Preserved all \(frames.count) frames in multi-page TIFF."]
            )
        }

        try ImageServiceWrite.write(image: first, to: outputURL, format: format, jpegQuality: jpegQuality)
        var notes = loadNotes(for: url)
        if frames.count > 1 {
            notes.append("Source has \(frames.count) frames; wrote frame 1. Use PDF target or TIFF to keep every frame.")
        }
        return ProcessingResult(
            outputURLs: [outputURL],
            bytesIn: FileIO.fileSize(at: url),
            bytesOut: FileIO.fileSize(at: outputURL),
            notes: notes
        )
    }

    /// Convert every frame of a multi-page image into separate files (ordered).
    public func convertAllFrames(
        url: URL,
        to format: DocumentFormat,
        outputDirectory: URL,
        jpegQuality: CGFloat = ImageService.highEncodeQuality
    ) throws -> ProcessingResult {
        let frames = try Self.syncLoadAllFrames(url: url)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let base = url.deletingPathExtension().lastPathComponent
        var outputs: [URL] = []
        for (idx, image) in frames.enumerated() {
            let out = outputDirectory.appendingPathComponent("\(base)-p\(idx + 1).\(format.pathExtension)")
            try ImageServiceWrite.write(image: image, to: out, format: format, jpegQuality: jpegQuality)
            outputs.append(out)
        }
        return ProcessingResult(
            outputURLs: outputs,
            bytesIn: FileIO.fileSize(at: url),
            bytesOut: outputs.reduce(0) { $0 + FileIO.fileSize(at: $1) },
            notes: ["Exported \(outputs.count) frame(s) in order."]
        )
    }

    public func loadImage(url: URL) throws -> NSImage {
        guard let image = try Self.syncLoadAllFrames(url: url).first else {
            throw DocuForgeError.conversionFailed("Could not load image \(url.lastPathComponent)")
        }
        return image
    }

    public func loadAllFrames(url: URL) throws -> [NSImage] {
        try Self.syncLoadAllFrames(url: url)
    }

    public func canDecode(url: URL) -> Bool {
        (try? loadImage(url: url)) != nil
    }

    // MARK: - Shared frame loader (usable from PDFService without actor hop issues)

    /// Load every frame/page from an image file (TIFF multipage, icon variants, etc.).
    nonisolated public static func syncLoadAllFrames(url: URL) throws -> [NSImage] {
        let format = DocumentFormat.detect(url: url)
        if format == .svg {
            if let image = rasterizeSVG(url: url) { return [image] }
            throw DocuForgeError.conversionFailed("Could not rasterize SVG \(url.lastPathComponent)")
        }

        if let frames = loadAllViaImageIO(url: url), !frames.isEmpty {
            return frames
        }
        if let image = NSImage(contentsOf: url) {
            return [image]
        }
        if let converted = try? sipsToPNG(url: url) {
            defer { try? FileManager.default.removeItem(at: converted) }
            if let image = NSImage(contentsOf: converted) { return [image] }
        }
        throw DocuForgeError.conversionFailed("Could not load image \(url.lastPathComponent)")
    }

    // MARK: - Private

    private func loadNotes(for url: URL) -> [String] {
        let format = DocumentFormat.detect(url: url)
        switch format {
        case .psd:
            return ["PSD support is limited to what ImageIO can composite (often the flattened preview)."]
        case .svg:
            return ["SVG was rasterized for bitmap export at full drawable size."]
        case .ico:
            return ["ICO may contain multiple sizes; frames are expanded when converting to PDF/TIFF."]
        default:
            return []
        }
    }

    nonisolated private static func loadAllViaImageIO(url: URL) -> [NSImage]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }
        var images: [NSImage] = []
        images.reserveCapacity(count)
        for i in 0..<count {
            // Prefer full-resolution frames without thumbnail downsampling.
            let options: [CFString: Any] = [
                kCGImageSourceShouldCache: true,
                kCGImageSourceShouldAllowFloat: true
            ]
            guard let cg = CGImageSourceCreateImageAtIndex(source, i, options as CFDictionary) else { continue }
            let size = NSSize(width: cg.width, height: cg.height)
            images.append(NSImage(cgImage: cg, size: size))
        }
        return images.isEmpty ? nil : images
    }

    nonisolated private static func rasterizeSVG(url: URL, maxEdge: CGFloat = 4096) -> NSImage? {
        if let image = NSImage(contentsOf: url), image.size.width > 0 {
            // If vector reports a tiny size, scale up for quality while keeping aspect.
            let longest = max(image.size.width, image.size.height)
            if longest > 0, longest < 512 {
                let scale = min(maxEdge / longest, 8)
                let target = NSSize(width: image.size.width * scale, height: image.size.height * scale)
                let scaled = NSImage(size: target)
                scaled.lockFocus()
                NSGraphicsContext.current?.imageInterpolation = .high
                image.draw(in: NSRect(origin: .zero, size: target),
                           from: NSRect(origin: .zero, size: image.size),
                           operation: .copy,
                           fraction: 1.0)
                scaled.unlockFocus()
                return scaled
            }
            return image
        }
        if let frames = loadAllViaImageIO(url: url), let first = frames.first { return first }
        return nil
    }

    nonisolated private static func sipsToPNG(url: URL) throws -> URL {
        let out = FileIO.temporaryURL(prefix: "sips", ext: "png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        process.arguments = ["-s", "format", "png", url.path, "--out", out.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw DocuForgeError.conversionFailed("sips could not convert \(url.lastPathComponent)")
        }
        return out
    }

    private func writeMultiPageTIFF(frames: [NSImage], to url: URL) throws {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.tiff.identifier as CFString, frames.count, nil) else {
            throw DocuForgeError.conversionFailed("Could not create multi-page TIFF destination.")
        }
        for image in frames {
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let cg = rep.cgImage else { continue }
            CGImageDestinationAddImage(dest, cg, nil)
        }
        guard CGImageDestinationFinalize(dest) else {
            throw DocuForgeError.conversionFailed("Failed to finalize multi-page TIFF.")
        }
        try (data as Data).write(to: url, options: .atomic)
    }
}
