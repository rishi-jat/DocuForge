import Foundation
import AppKit
import Vision
import CoreGraphics

/// Detect and rewrite text that lives as *pixels* inside screenshots / photos.
/// This is the main “edit text in a screenshot” feature (OCR → cover → draw).
public actor ScreenshotTextEditorService {
    public init() {}

    public struct TextBlock: Identifiable, Sendable, Equatable {
        public let id: UUID
        /// Original OCR text
        public var originalText: String
        /// User-editable replacement
        public var editedText: String
        /// Pixel bounds in image coordinates (origin top-left, y down) — matches UI drawing.
        public let pixelBounds: CGRect
        public let confidence: Float

        public init(
            id: UUID = UUID(),
            originalText: String,
            editedText: String? = nil,
            pixelBounds: CGRect,
            confidence: Float
        ) {
            self.id = id
            self.originalText = originalText
            self.editedText = editedText ?? originalText
            self.pixelBounds = pixelBounds
            self.confidence = confidence
        }

        public var isModified: Bool {
            originalText != editedText
        }
    }

    public struct DetectResult: Sendable {
        public let blocks: [TextBlock]
        public let imagePixelSize: CGSize
        public let averageConfidence: Float
    }

    /// Flatten retina / multi-rep images so 1 point == 1 pixel (boxes align with drawing).
    public func normalizedImage(_ image: NSImage) -> NSImage {
        guard let cg = cgImage(from: image) else { return image }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// OCR the image and return each line/word with pixel bounds for editing.
    public func detectText(
        in image: NSImage,
        languages: [String] = ["en-US"],
        level: VNRequestTextRecognitionLevel = .accurate
    ) async throws -> DetectResult {
        let image = normalizedImage(image)
        guard let cg = cgImage(from: image) else {
            throw DocuForgeError.ocrFailed("Could not read image pixels for text detection.")
        }
        let width = cg.width
        let height = cg.height
        guard width > 0, height > 0 else {
            throw DocuForgeError.ocrFailed("Image has zero size.")
        }

        let raw = try await recognizeRaw(cgImage: cg, languages: languages, level: level)
        var blocks: [TextBlock] = []
        var confidences: [Float] = []

        for item in raw {
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            // Vision box: normalized, origin bottom-left
            let bb = item.boundingBox
            let x = bb.origin.x * CGFloat(width)
            let w = bb.size.width * CGFloat(width)
            let h = bb.size.height * CGFloat(height)
            // Convert to top-left origin for drawing with NSImage
            let yTop = (1.0 - bb.origin.y - bb.size.height) * CGFloat(height)
            let pixel = CGRect(x: x, y: yTop, width: max(1, w), height: max(1, h))

            blocks.append(TextBlock(
                originalText: text,
                editedText: text,
                pixelBounds: pixel,
                confidence: item.confidence
            ))
            confidences.append(item.confidence)
        }

        // Stable reading order: top-to-bottom, then left-to-right
        blocks.sort {
            if abs($0.pixelBounds.minY - $1.pixelBounds.minY) > 8 {
                return $0.pixelBounds.minY < $1.pixelBounds.minY
            }
            return $0.pixelBounds.minX < $1.pixelBounds.minX
        }

        let avg = confidences.isEmpty ? 0 : confidences.reduce(0, +) / Float(confidences.count)
        return DetectResult(
            blocks: blocks,
            imagePixelSize: CGSize(width: width, height: height),
            averageConfidence: avg
        )
    }

    /// Apply all modified blocks: cover original pixels and draw new text.
    public func applyEdits(image: NSImage, blocks: [TextBlock]) throws -> NSImage {
        let image = normalizedImage(image)
        let modified = blocks.filter(\.isModified)
        guard !modified.isEmpty else { return image }
        guard let cg = cgImage(from: image) else {
            throw DocuForgeError.conversionFailed("Could not read image for text rewrite.")
        }
        let width = cg.width
        let height = cg.height
        let colorSpace = cg.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw DocuForgeError.conversionFailed("Could not create drawing context.")
        }

        // Draw original image (CGContext origin is bottom-left)
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

        for block in modified {
            let b = block.pixelBounds.integral.insetBy(dx: -2, dy: -2)
            // Convert top-left rect → bottom-left for CGContext
            let cgRect = CGRect(
                x: b.origin.x,
                y: CGFloat(height) - b.origin.y - b.height,
                width: b.width,
                height: b.height
            )

            let fill = sampleBackgroundColor(cg: cg, topLeftRect: b, imageHeight: height)
            ctx.setFillColor(fill)
            ctx.fill(cgRect.insetBy(dx: -1, dy: -1))

            let fontSize = max(8, min(72, b.height * 0.82))
            let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
            let color = CGColor(gray: 0.05, alpha: 1)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color
            ]
            let attr = NSAttributedString(string: block.editedText, attributes: attrs)
            let line = CTLineCreateWithAttributedString(attr)
            let lineBounds = CTLineGetBoundsWithOptions(line, [])
            // Position baseline near bottom of box (CG coords)
            let textX = cgRect.minX + 2
            let textY = cgRect.minY + max(1, (cgRect.height - lineBounds.height) / 2 - lineBounds.origin.y)
            ctx.textPosition = CGPoint(x: textX, y: textY)
            CTLineDraw(line, ctx)
        }

        guard let out = ctx.makeImage() else {
            throw DocuForgeError.conversionFailed("Failed to render edited screenshot.")
        }
        return NSImage(cgImage: out, size: NSSize(width: width, height: height))
    }

    /// Convenience: detect + replace all occurrences of `search` with `replace` in the image.
    public func replaceText(
        in image: NSImage,
        search: String,
        replace: String,
        caseSensitive: Bool = false
    ) async throws -> (image: NSImage, changed: Int) {
        let detected = try await detectText(in: image)
        var blocks = detected.blocks
        var changed = 0
        for i in blocks.indices {
            let original = blocks[i].originalText
            let newValue: String
            if caseSensitive {
                if original.contains(search) {
                    newValue = original.replacingOccurrences(of: search, with: replace)
                } else {
                    continue
                }
            } else {
                // Case-insensitive replace while keeping simple path
                if original.range(of: search, options: .caseInsensitive) != nil {
                    newValue = original.replacingOccurrences(
                        of: search,
                        with: replace,
                        options: .caseInsensitive
                    )
                } else {
                    continue
                }
            }
            if newValue != original {
                blocks[i].editedText = newValue
                changed += 1
            }
        }
        guard changed > 0 else { return (image, 0) }
        let out = try applyEdits(image: image, blocks: blocks)
        return (out, changed)
    }

    // MARK: - Helpers

    private struct RawObs: Sendable {
        let text: String
        let confidence: Float
        let boundingBox: CGRect
    }

    private func recognizeRaw(
        cgImage: CGImage,
        languages: [String],
        level: VNRequestTextRecognitionLevel
    ) async throws -> [RawObs] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: DocuForgeError.ocrFailed(error.localizedDescription))
                    return
                }
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                // Map to Sendable values before leaving the callback (Swift 6).
                var mapped: [RawObs] = []
                mapped.reserveCapacity(observations.count)
                for obs in observations {
                    guard let top = obs.topCandidates(1).first else { continue }
                    mapped.append(RawObs(
                        text: top.string,
                        confidence: top.confidence,
                        boundingBox: obs.boundingBox
                    ))
                }
                continuation.resume(returning: mapped)
            }
            request.recognitionLevel = level
            request.usesLanguageCorrection = true
            request.recognitionLanguages = languages
            if #available(macOS 13.0, *) {
                request.revision = VNRecognizeTextRequestRevision3
            }

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: DocuForgeError.ocrFailed(error.localizedDescription))
            }
        }
    }

    private func cgImage(from image: NSImage) -> CGImage? {
        var rect = CGRect(origin: .zero, size: image.size)
        if let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
            return cg
        }
        // Fallback via bitmap rep
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.cgImage
    }

    /// Sample near the border of the text box for a plausible background color.
    private func sampleBackgroundColor(cg: CGImage, topLeftRect: CGRect, imageHeight: Int) -> CGColor {
        // Sample a few points just outside the box (top-left coords → pixel)
        let candidates: [CGPoint] = [
            CGPoint(x: topLeftRect.minX - 3, y: topLeftRect.minY - 3),
            CGPoint(x: topLeftRect.maxX + 3, y: topLeftRect.minY - 3),
            CGPoint(x: topLeftRect.minX - 3, y: topLeftRect.maxY + 3),
            CGPoint(x: topLeftRect.midX, y: topLeftRect.minY - 4)
        ]
        var samples: [(r: CGFloat, g: CGFloat, b: CGFloat)] = []
        for p in candidates {
            let px = Int(p.x.rounded())
            let pyTop = Int(p.y.rounded())
            guard px >= 0, px < cg.width, pyTop >= 0, pyTop < imageHeight else { continue }
            let pyBottom = imageHeight - 1 - pyTop
            if let c = pixelColor(cg: cg, x: px, y: pyBottom) {
                samples.append(c)
            }
        }
        if samples.isEmpty {
            return CGColor(gray: 1, alpha: 1)
        }
        let r = samples.map(\.r).reduce(0, +) / CGFloat(samples.count)
        let g = samples.map(\.g).reduce(0, +) / CGFloat(samples.count)
        let b = samples.map(\.b).reduce(0, +) / CGFloat(samples.count)
        return CGColor(red: r, green: g, blue: b, alpha: 1)
    }

    private func pixelColor(cg: CGImage, x: Int, y: Int) -> (r: CGFloat, g: CGFloat, b: CGFloat)? {
        guard let data = cg.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return nil }
        let bytesPerPixel = max(1, cg.bitsPerPixel / 8)
        let bytesPerRow = cg.bytesPerRow
        let offset = y * bytesPerRow + x * bytesPerPixel
        let length = CFDataGetLength(data)
        guard offset + 2 < length else { return nil }
        // Assume RGBA or RGB
        let r = CGFloat(ptr[offset]) / 255
        let g = CGFloat(ptr[offset + 1]) / 255
        let b = CGFloat(ptr[offset + 2]) / 255
        return (r, g, b)
    }
}
