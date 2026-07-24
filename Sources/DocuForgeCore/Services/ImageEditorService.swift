import Foundation
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import UniformTypeIdentifiers

/// Destructive/non-destructive image editing helpers (crop, resize, adjustments).
public actor ImageEditorService {
    private let context = CIContext(options: [.useSoftwareRenderer: false])

    public init() {}

    public struct Adjustments: Sendable, Equatable {
        public var brightness: Double // -1...1
        public var contrast: Double   // 0...2, 1 = neutral
        public var saturation: Double // 0...2, 1 = neutral

        public init(brightness: Double = 0, contrast: Double = 1, saturation: Double = 1) {
            self.brightness = brightness
            self.contrast = contrast
            self.saturation = saturation
        }

        public var isIdentity: Bool {
            abs(brightness) < 0.001 && abs(contrast - 1) < 0.001 && abs(saturation - 1) < 0.001
        }
    }

    public func load(url: URL) throws -> NSImage {
        guard let image = NSImage(contentsOf: url) else {
            throw DocuForgeError.conversionFailed("Could not open image \(url.lastPathComponent)")
        }
        return image
    }

    public func apply(
        image: NSImage,
        cropNormalized: CGRect?, // null = no crop; origin bottom-left style 0...1
        targetSize: CGSize?,     // null = keep size after crop
        adjustments: Adjustments
    ) throws -> NSImage {
        guard var ci = ciImage(from: image) else {
            throw DocuForgeError.conversionFailed("Could not create CIImage.")
        }
        let extent = ci.extent

        if let crop = cropNormalized {
            let r = CGRect(
                x: extent.minX + crop.origin.x * extent.width,
                y: extent.minY + crop.origin.y * extent.height,
                width: max(1, crop.size.width * extent.width),
                height: max(1, crop.size.height * extent.height)
            )
            ci = ci.cropped(to: r)
        }

        if !adjustments.isIdentity {
            let filter = CIFilter.colorControls()
            filter.inputImage = ci
            filter.brightness = Float(adjustments.brightness)
            filter.contrast = Float(adjustments.contrast)
            filter.saturation = Float(adjustments.saturation)
            if let out = filter.outputImage {
                ci = out
            }
        }

        if let targetSize, targetSize.width > 0, targetSize.height > 0 {
            let sx = targetSize.width / ci.extent.width
            let sy = targetSize.height / ci.extent.height
            ci = ci.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        }

        guard let cg = context.createCGImage(ci, from: ci.extent) else {
            throw DocuForgeError.conversionFailed("Image render failed.")
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    public func save(
        image: NSImage,
        to url: URL,
        format: DocumentFormat,
        jpegQuality: CGFloat = ImageService.highEncodeQuality
    ) throws -> ProcessingResult {
        try ImageServiceWrite.write(image: image, to: url, format: format, jpegQuality: jpegQuality)
        return ProcessingResult(
            outputURLs: [url],
            bytesOut: FileIO.fileSize(at: url),
            notes: ["Saved edited image as \(format.displayName)."]
        )
    }

    public func canSaveNative(format: DocumentFormat) -> Bool {
        format.isImage && format != .svg && format != .psd
    }

    /// Read an image from the general pasteboard (screenshots, copy from Preview, etc.).
    public func clipboardImage() -> NSImage? {
        let pb = NSPasteboard.general
        if let img = NSImage(pasteboard: pb) { return img }
        if let data = pb.data(forType: .png) ?? pb.data(forType: .tiff),
           let img = NSImage(data: data) {
            return img
        }
        return nil
    }

    private func ciImage(from image: NSImage) -> CIImage? {
        if let tiff = image.tiffRepresentation {
            return CIImage(data: tiff)
        }
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return CIImage(cgImage: cg)
    }
}
