import Foundation
import AppKit
import PDFKit
import CoreGraphics

/// Layout-preserving PDF text find / click-select / cover-replace / markup.
/// Shared by the live canvas and automated tests.
public enum PDFTextEditEngine {

    public struct Match: Sendable, Equatable {
        public let pageIndex: Int
        public let bounds: CGRect
        public let text: String
        public init(pageIndex: Int, bounds: CGRect, text: String) {
            self.pageIndex = pageIndex
            self.bounds = bounds
            self.text = text
        }
    }

    public struct Selection: Sendable, Equatable {
        public let pageIndex: Int
        public let bounds: CGRect
        public let text: String
        public let fontSize: CGFloat
        public init(pageIndex: Int, bounds: CGRect, text: String, fontSize: CGFloat = 12) {
            self.pageIndex = pageIndex
            self.bounds = bounds
            self.text = text
            self.fontSize = fontSize
        }
    }

    public struct PageLine: Sendable, Identifiable, Equatable {
        public var id: Int { index }
        public let index: Int
        public let pageIndex: Int
        public let bounds: CGRect
        public let text: String
        public let fontSize: CGFloat
        public init(index: Int, pageIndex: Int, bounds: CGRect, text: String, fontSize: CGFloat) {
            self.index = index
            self.pageIndex = pageIndex
            self.bounds = bounds
            self.text = text
            self.fontSize = fontSize
        }
    }

    // MARK: - Find

    public static func findMatches(
        in document: PDFDocument,
        query: String,
        caseSensitive: Bool
    ) -> [Match] {
        guard !query.isEmpty else { return [] }
        var options: NSString.CompareOptions = []
        if !caseSensitive { options.insert(.caseInsensitive) }

        var hits: [Match] = []
        for i in 0..<document.pageCount {
            guard let page = document.page(at: i),
                  let pageText = page.string as NSString?,
                  pageText.length > 0 else { continue }

            var searchRange = NSRange(location: 0, length: pageText.length)
            while searchRange.length > 0 {
                let found = pageText.range(of: query, options: options, range: searchRange)
                if found.location == NSNotFound { break }
                if let bounds = boundsForCharacterRange(page: page, document: document, range: found) {
                    hits.append(Match(pageIndex: i, bounds: bounds, text: pageText.substring(with: found)))
                }
                let next = found.location + max(found.length, 1)
                if next >= pageText.length { break }
                searchRange = NSRange(location: next, length: pageText.length - next)
            }
        }
        return hits
    }

    // MARK: - Click select

    public static func selectText(
        page: PDFPage,
        pageIndex: Int,
        point: CGPoint,
        preferLine: Bool
    ) -> Selection? {
        if preferLine, let s = usableSelection(page.selectionForLine(at: point), page: page, pageIndex: pageIndex) {
            return s
        }
        if let s = usableSelection(page.selectionForWord(at: point), page: page, pageIndex: pageIndex) {
            return s
        }
        if !preferLine, let s = usableSelection(page.selectionForLine(at: point), page: page, pageIndex: pageIndex) {
            return s
        }
        let idx = page.characterIndex(at: point)
        if idx != NSNotFound, let s = selectionAroundCharacter(page: page, pageIndex: pageIndex, index: idx, preferLine: preferLine) {
            return s
        }
        for r: CGFloat in [2, 4, 8, 12, 18, 28, 40, 56] {
            for angle in stride(from: 0.0, to: 360.0, by: 30.0) {
                let rad = angle * .pi / 180
                let p = CGPoint(x: point.x + r * cos(rad), y: point.y + r * sin(rad))
                if let s = usableSelection(page.selectionForWord(at: p), page: page, pageIndex: pageIndex) {
                    return s
                }
                let cidx = page.characterIndex(at: p)
                if cidx != NSNotFound,
                   let s = selectionAroundCharacter(page: page, pageIndex: pageIndex, index: cidx, preferLine: preferLine) {
                    return s
                }
            }
        }
        return nil
    }

    // MARK: - Page lines

    public static func extractLines(page: PDFPage, pageIndex: Int) -> [PageLine] {
        guard let full = page.string, !full.isEmpty else { return [] }
        let ns = full as NSString
        var lines: [PageLine] = []
        var lineStart = 0
        var lineIndex = 0

        func flush(end: Int) {
            guard end > lineStart else { return }
            let range = NSRange(location: lineStart, length: end - lineStart)
            let raw = ns.substring(with: range)
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            let trimRange = (raw as NSString).range(of: text)
            let absolute: NSRange
            if trimRange.location != NSNotFound {
                absolute = NSRange(location: lineStart + trimRange.location, length: trimRange.length)
            } else {
                absolute = range
            }
            guard let bounds = approximateBounds(page: page, range: absolute), !bounds.isNull else { return }
            let fontSize = estimateFontSize(bounds: bounds, sampleText: text)
            lines.append(PageLine(index: lineIndex, pageIndex: pageIndex, bounds: bounds, text: text, fontSize: fontSize))
            lineIndex += 1
        }

        for i in 0..<ns.length {
            let ch = ns.character(at: i)
            if ch == 10 || ch == 13 || ch == 0x0C {
                flush(end: i)
                lineStart = i + 1
            }
        }
        flush(end: ns.length)
        return lines
    }

    // MARK: - Replace (high visual fidelity)

    /// Cover original glyphs and draw replacement sized like the original.
    /// Uses page-region paint so the new text size matches (freeText alone looks wrong).
    @discardableResult
    public static func coverAndReplace(
        on page: PDFPage,
        bounds: CGRect,
        newText: String,
        originalText: String = ""
    ) -> Bool {
        coverAndReplaceHighFidelity(on: page, bounds: bounds, newText: newText, originalText: originalText)
    }

    @discardableResult
    public static func coverAndReplaceHighFidelity(
        on page: PDFPage,
        bounds: CGRect,
        newText: String,
        originalText: String
    ) -> Bool {
        guard !bounds.isNull, bounds.width > 0.5, bounds.height > 0.5 else { return false }
        let sample = originalText.isEmpty ? newText : originalText
        let fontSize = estimateFontSize(bounds: bounds, sampleText: sample)
        let font = preferredFont(size: fontSize)
        let textSize = measure(newText, font: font)
        let height = max(bounds.height, textSize.height * 0.9)
        let width = max(bounds.width, textSize.width + 4)
        let drawBounds = CGRect(
            x: bounds.minX,
            y: bounds.midY - height / 2,
            width: width,
            height: height
        )
        guard let image = renderTextImage(
            text: newText,
            font: font,
            textColor: .black,
            background: .white,
            size: CGSize(width: ceil(drawBounds.width * 2) / 2, height: ceil(drawBounds.height * 2) / 2)
        ) else {
            return addFreeTextFallback(on: page, bounds: drawBounds, text: newText, font: font)
        }
        return burnImageOntoPage(page: page, image: image, bounds: drawBounds)
    }

    public static func replaceAll(
        in document: PDFDocument,
        query: String,
        replacement: String,
        caseSensitive: Bool
    ) -> Int {
        let hits = findMatches(in: document, query: query, caseSensitive: caseSensitive)
        guard !hits.isEmpty else { return 0 }
        // Group by page so we don't re-rasterize a page per hit more than needed in sequence
        for hit in hits.reversed() {
            guard let page = document.page(at: hit.pageIndex) else { continue }
            _ = coverAndReplace(on: page, bounds: hit.bounds, newText: replacement, originalText: hit.text)
        }
        return hits.count
    }

    // MARK: - Markup

    public static func applyMarkup(
        selection: PDFSelection,
        type: PDFAnnotationSubtype,
        color: NSColor
    ) -> Int {
        var count = 0
        let byLine = selection.selectionsByLine()
        let pieces: [PDFSelection] = byLine.isEmpty ? [selection] : byLine
        for piece in pieces {
            for page in piece.pages {
                var bounds = piece.bounds(for: page)
                guard !bounds.isNull, bounds.width > 0.5, bounds.height > 0.5 else { continue }
                if type == .highlight {
                    bounds = bounds.insetBy(dx: -0.5, dy: -1.0)
                }
                let ann = PDFAnnotation(bounds: bounds, forType: type, withProperties: nil)
                ann.color = color
                ann.shouldDisplay = true
                ann.shouldPrint = true
                page.addAnnotation(ann)
                count += 1
            }
        }
        return count
    }

    public static func applyMarkupAtPoint(
        page: PDFPage,
        pageIndex: Int,
        point: CGPoint,
        type: PDFAnnotationSubtype,
        color: NSColor,
        preferLine: Bool = false
    ) -> (count: Int, text: String?) {
        guard let sel = selectText(page: page, pageIndex: pageIndex, point: point, preferLine: preferLine) else {
            return (0, nil)
        }
        var bounds = sel.bounds
        if type == .highlight {
            bounds = bounds.insetBy(dx: -0.5, dy: -1.0)
        }
        let ann = PDFAnnotation(bounds: bounds, forType: type, withProperties: nil)
        ann.color = color
        ann.shouldDisplay = true
        ann.shouldPrint = true
        page.addAnnotation(ann)
        return (1, sel.text)
    }

    public static func pageHasExtractableText(_ page: PDFPage) -> Bool {
        guard let s = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return !s.isEmpty
    }

    public static func estimateFontSize(bounds: CGRect, sampleText: String) -> CGFloat {
        let byHeight = bounds.height * 0.94
        if sampleText.count >= 2, bounds.width > 1 {
            let avgAdvance = bounds.width / CGFloat(max(1, sampleText.count))
            let byWidth = avgAdvance * 1.7
            let blended = byHeight * 0.8 + min(byHeight * 1.2, byWidth) * 0.2
            return max(6, min(72, blended))
        }
        return max(6, min(72, byHeight))
    }

    // MARK: - Page paint helpers

    @discardableResult
    public static func burnImageOntoPage(page: PDFPage, image: NSImage, bounds: CGRect) -> Bool {
        guard let document = page.document else { return false }
        let pageIndex = document.index(for: page)
        guard pageIndex != NSNotFound else { return false }

        let media = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2.0
        let pxW = max(1, Int(media.width * scale))
        let pxH = max(1, Int(media.height * scale))

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pxW,
            pixelsHigh: pxH,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return false }

        NSGraphicsContext.saveGraphicsState()
        guard let gc = NSGraphicsContext(bitmapImageRep: rep) else {
            NSGraphicsContext.restoreGraphicsState()
            return false
        }
        NSGraphicsContext.current = gc
        let cg = gc.cgContext
        let px = CGSize(width: pxW, height: pxH)

        cg.setFillColor(NSColor.white.cgColor)
        cg.fill(CGRect(origin: .zero, size: px))
        cg.saveGState()
        // PDF page draw expects bottom-left origin; bitmap is bottom-left in CGContext too
        cg.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: cg)
        cg.restoreGState()

        // Draw replacement image in PDF coordinates (bottom-left)
        if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let imgRect = CGRect(
                x: bounds.minX * scale,
                y: bounds.minY * scale,
                width: bounds.width * scale,
                height: bounds.height * scale
            )
            cg.draw(cgImage, in: imgRect)
        }
        NSGraphicsContext.restoreGraphicsState()

        let outImage = NSImage(size: NSSize(width: pxW, height: pxH))
        outImage.addRepresentation(rep)
        guard let newPage = PDFPage(image: outImage) else { return false }
        newPage.rotation = page.rotation
        // Preserve crop box roughly
        document.removePage(at: pageIndex)
        document.insert(newPage, at: pageIndex)
        return true
    }

    // MARK: - Private

    private static func preferredFont(size: CGFloat) -> NSFont {
        NSFont(name: "Helvetica", size: size)
            ?? NSFont(name: "Arial", size: size)
            ?? .systemFont(ofSize: size)
    }

    private static func measure(_ text: String, font: NSFont) -> CGSize {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let s = (text as NSString).size(withAttributes: attrs)
        return CGSize(width: ceil(s.width), height: ceil(s.height))
    }

    private static func renderTextImage(
        text: String,
        font: NSFont,
        textColor: NSColor,
        background: NSColor,
        size: CGSize
    ) -> NSImage? {
        let w = max(1, Int(ceil(size.width)))
        let h = max(1, Int(ceil(size.height)))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: w,
            pixelsHigh: h,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
            NSGraphicsContext.restoreGraphicsState()
            return nil
        }
        NSGraphicsContext.current = ctx
        background.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: w, height: h)).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor
        ]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let x: CGFloat = 1
        let y = max(0, (CGFloat(h) - textSize.height) / 2)
        (text as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: NSSize(width: w, height: h))
        image.addRepresentation(rep)
        return image
    }

    private static func addFreeTextFallback(on page: PDFPage, bounds: CGRect, text: String, font: NSFont) -> Bool {
        let cover = PDFAnnotation(bounds: bounds.insetBy(dx: -1, dy: -0.5), forType: .square, withProperties: nil)
        cover.color = .white
        cover.interiorColor = .white
        cover.border = PDFBorder()
        cover.border?.lineWidth = 0
        page.addAnnotation(cover)
        let box = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
        box.contents = text
        box.font = font
        box.fontColor = .black
        box.color = .clear
        box.alignment = .left
        page.addAnnotation(box)
        return true
    }

    private static func boundsForCharacterRange(page: PDFPage, document: PDFDocument, range: NSRange) -> CGRect? {
        let endIndex = max(range.location, NSMaxRange(range) - 1)
        if let selection = document.selection(
            from: page,
            atCharacterIndex: range.location,
            to: page,
            atCharacterIndex: endIndex
        ) {
            let bounds = selection.bounds(for: page)
            if !bounds.isNull, bounds.width > 0.2, bounds.height > 0.2 { return bounds }
        }
        return approximateBounds(page: page, range: range)
    }

    private static func usableSelection(_ selection: PDFSelection?, page: PDFPage, pageIndex: Int) -> Selection? {
        guard let selection,
              let raw = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        let bounds = selection.bounds(for: page)
        guard !bounds.isNull, bounds.width > 0.4, bounds.height > 0.4 else { return nil }
        return Selection(
            pageIndex: pageIndex,
            bounds: bounds,
            text: raw,
            fontSize: estimateFontSize(bounds: bounds, sampleText: raw)
        )
    }

    private static func selectionAroundCharacter(
        page: PDFPage,
        pageIndex: Int,
        index: Int,
        preferLine: Bool
    ) -> Selection? {
        guard let pageText = page.string as NSString?, index >= 0, index < pageText.length else { return nil }
        let point = page.characterBounds(at: index).origin
        if preferLine, let s = usableSelection(page.selectionForLine(at: point), page: page, pageIndex: pageIndex) {
            return s
        }
        if let s = usableSelection(page.selectionForWord(at: point), page: page, pageIndex: pageIndex) {
            return s
        }
        let bounds = page.characterBounds(at: index)
        if !bounds.isNull, bounds.width > 0, bounds.height > 0 {
            let ch = pageText.substring(with: NSRange(location: index, length: 1))
            if !ch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return Selection(
                    pageIndex: pageIndex,
                    bounds: bounds,
                    text: ch,
                    fontSize: estimateFontSize(bounds: bounds, sampleText: ch)
                )
            }
        }
        return nil
    }

    private static func approximateBounds(page: PDFPage, range: NSRange) -> CGRect? {
        guard range.location != NSNotFound, range.length > 0 else { return nil }
        var union = CGRect.null
        for i in range.location..<NSMaxRange(range) {
            let b = page.characterBounds(at: i)
            if !b.isNull { union = union.union(b) }
        }
        if union.isNull || union.width < 0.2 { return nil }
        return union
    }
}
