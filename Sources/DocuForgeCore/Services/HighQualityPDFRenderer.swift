import Foundation
import AppKit
import CoreGraphics
import CoreText

/// Multi-page, layout-preserving PDF writer using AppKit text layout.
///
/// Unlike a single-frame CTFramesetter draw (which often clips to one page when
/// the PDF coordinate system is unflipped), this uses NSTextStorage +
/// NSLayoutManager containers so **every page of content** is emitted in order.
public enum HighQualityPDFRenderer: Sendable {

    public static let usLetter = CGSize(width: 612, height: 792)
    public static let defaultMargin: CGFloat = 54

    // MARK: - Public API

    /// Render plain text to a multi-page PDF, preserving paragraph structure.
    public static func writePlainText(
        _ text: String,
        to outputURL: URL,
        pageSize: CGSize = usLetter,
        margin: CGFloat = defaultMargin,
        font: NSFont = .systemFont(ofSize: 12),
        bytesIn: Int64 = 0
    ) throws -> ProcessingResult {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.alignment = .natural
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraph
        ]
        // Honor form-feed page breaks from source documents.
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let attr = NSAttributedString(string: normalized, attributes: attrs)
        return try writeAttributedString(attr, to: outputURL, pageSize: pageSize, margin: margin, bytesIn: bytesIn)
    }

    /// Render rich text (RTF/HTML-derived) to multi-page PDF with fonts and styles.
    public static func writeAttributedString(
        _ attributed: NSAttributedString,
        to outputURL: URL,
        pageSize: CGSize = usLetter,
        margin: CGFloat = defaultMargin,
        bytesIn: Int64 = 0
    ) throws -> ProcessingResult {
        let pageCount = try render(attributed, to: outputURL, pageSize: pageSize, margin: margin)
        guard pageCount > 0 else {
            throw DocuForgeError.conversionFailed("Produced an empty PDF.")
        }
        return ProcessingResult(
            outputURLs: [outputURL],
            bytesIn: bytesIn,
            bytesOut: FileIO.fileSize(at: outputURL),
            notes: pageCount == 1
                ? ["Rendered 1 page (high-quality layout)."]
                : ["Rendered \(pageCount) pages in order (high-quality layout)."]
        )
    }

    // MARK: - Engine

    @discardableResult
    private static func render(
        _ attributed: NSAttributedString,
        to outputURL: URL,
        pageSize: CGSize,
        margin: CGFloat
    ) throws -> Int {
        // Split on explicit page breaks first so multi-page source docs keep structure.
        let segments = splitOnPageBreaks(attributed)
        let contentWidth = max(1, pageSize.width - margin * 2)
        let contentHeight = max(1, pageSize.height - margin * 2)
        let contentSize = NSSize(width: contentWidth, height: contentHeight)

        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw DocuForgeError.conversionFailed("Could not create PDF context.")
        }

        var totalPages = 0

        for segment in segments {
            if segment.length == 0 {
                // Explicit empty page break still yields a blank page only if intentional;
                // skip pure empties between breaks.
                continue
            }
            let pages = layoutPages(for: segment, contentSize: contentSize)
            for pageRange in pages {
                var box = mediaBox
                context.beginPage(mediaBox: &box)

                // Flip to AppKit top-left coordinates for text drawing.
                context.saveGState()
                context.translateBy(x: 0, y: pageSize.height)
                context.scaleBy(x: 1, y: -1)

                // White background
                context.setFillColor(NSColor.white.cgColor)
                context.fill(CGRect(origin: .zero, size: pageSize))

                let drawRect = CGRect(x: margin, y: margin, width: contentWidth, height: contentHeight)
                NSGraphicsContext.saveGraphicsState()
                let ns = NSGraphicsContext(cgContext: context, flipped: true)
                NSGraphicsContext.current = ns

                let slice = segment.attributedSubstring(from: pageRange)
                drawPageSlice(slice, in: drawRect, contentSize: contentSize)

                NSGraphicsContext.restoreGraphicsState()
                context.restoreGState()
                context.endPage()
                totalPages += 1
            }
        }

        // Ensure at least one page for empty input
        if totalPages == 0 {
            var box = mediaBox
            context.beginPage(mediaBox: &box)
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(origin: .zero, size: pageSize))
            context.endPage()
            totalPages = 1
        }

        context.closePDF()
        try (data as Data).write(to: outputURL, options: .atomic)
        return totalPages
    }

    /// Lay out an attributed string into glyph ranges, one per page, using NSLayoutManager.
    private static func layoutPages(for attributed: NSAttributedString, contentSize: NSSize) -> [NSRange] {
        let storage = NSTextStorage(attributedString: attributed)
        let layoutManager = NSLayoutManager()
        layoutManager.usesDefaultHyphenation = false
        storage.addLayoutManager(layoutManager)

        var ranges: [NSRange] = []
        var glyphIndex = 0

        // Force glyph generation
        _ = layoutManager.numberOfGlyphs

        while glyphIndex < layoutManager.numberOfGlyphs {
            let container = NSTextContainer(size: contentSize)
            container.widthTracksTextView = false
            container.heightTracksTextView = false
            container.lineFragmentPadding = 0
            layoutManager.addTextContainer(container)

            // Ensure layout for this container
            let glyphRange = layoutManager.glyphRange(for: container)
            if glyphRange.length == 0 {
                // Safety: advance at least one glyph to avoid infinite loop
                glyphIndex += 1
                continue
            }

            let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            ranges.append(charRange)
            glyphIndex = NSMaxRange(glyphRange)
        }

        // If there were no glyphs (e.g. only attachments edge case), one empty range
        if ranges.isEmpty, attributed.length > 0 {
            ranges.append(NSRange(location: 0, length: attributed.length))
        }
        return ranges
    }

    private static func drawPageSlice(_ slice: NSAttributedString, in rect: CGRect, contentSize: NSSize) {
        let storage = NSTextStorage(attributedString: slice)
        let layoutManager = NSLayoutManager()
        layoutManager.usesDefaultHyphenation = false
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: contentSize)
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        let glyphRange = layoutManager.glyphRange(for: container)
        layoutManager.drawBackground(forGlyphRange: glyphRange, at: rect.origin)
        layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: rect.origin)
    }

    /// Split on form-feed (U+000C) and common page-break markers while keeping attributes.
    private static func splitOnPageBreaks(_ attributed: NSAttributedString) -> [NSAttributedString] {
        let full = attributed.string as NSString
        var segments: [NSAttributedString] = []
        var start = 0
        let length = full.length
        var i = 0
        while i < length {
            let ch = full.character(at: i)
            if ch == 0x0C { // form feed
                if i > start {
                    segments.append(attributed.attributedSubstring(from: NSRange(location: start, length: i - start)))
                }
                start = i + 1
            }
            i += 1
        }
        if start < length {
            segments.append(attributed.attributedSubstring(from: NSRange(location: start, length: length - start)))
        }
        if segments.isEmpty {
            segments.append(attributed)
        }
        return segments
    }
}
