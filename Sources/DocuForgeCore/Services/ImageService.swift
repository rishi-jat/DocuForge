import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

/// Image format conversion and inspection via ImageIO / AppKit.
public actor ImageService {
    public init() {}

    public func convert(url: URL, to format: DocumentFormat, outputURL: URL, jpegQuality: CGFloat = 0.9) throws -> ProcessingResult {
        guard format.isImage else {
            throw DocuForgeError.invalidInput("Target must be an image format.")
        }
        guard let image = NSImage(contentsOf: url) else {
            throw DocuForgeError.conversionFailed("Could not load \(url.lastPathComponent)")
        }
        try ImageServiceWrite.write(image: image, to: outputURL, format: format, jpegQuality: jpegQuality)
        return ProcessingResult(
            outputURLs: [outputURL],
            bytesIn: FileIO.fileSize(at: url),
            bytesOut: FileIO.fileSize(at: outputURL)
        )
    }

    public func loadImage(url: URL) throws -> NSImage {
        guard let image = NSImage(contentsOf: url) else {
            throw DocuForgeError.conversionFailed("Could not load \(url.lastPathComponent)")
        }
        return image
    }
}
