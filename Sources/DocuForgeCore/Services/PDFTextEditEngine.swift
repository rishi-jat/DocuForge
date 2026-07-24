import Foundation
import AppKit
import PDFKit
import CoreGraphics
import CoreText

/// PDF text find / select / replace / markup.
/// Replace paints glyphs at matched size (Pages/Canva-style visual edit on PDF).
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
        public let isBold: Bool
        public init(pageIndex: Int, bounds: CGRect, text: String, fontSize: CGFloat = 12, isBold: Bool = false) {
            self.pageIndex = pageIndex
            self.bounds = bounds
            self.text = text
            self.fontSize = fontSize
            self.isBold = isBold
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

    public struct ReplaceOp: Sendable {
        public let bounds: CGRect
        public let originalText: String
        public let newText: String
        public init(bounds: CGRect, originalText: String, newText: String) {
            self.bounds = bounds
            self.originalText = originalText
            self.newText = newText
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

    // MARK: - Click / point select

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

    public static func selectionFromPDFSelection(_ pdfSel: PDFSelection, document: PDFDocument) -> Selection? {
        guard let raw = pdfSel.string?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let pages = pdfSel.pages
        guard let page = pages.first else { return nil }
        let pageIndex = document.index(for: page)
        guard pageIndex != NSNotFound else { return nil }
        let bounds = pdfSel.bounds(for: page)
        guard !bounds.isNull, bounds.width > 0.4, bounds.height > 0.4 else { return nil }
        let fontSize = estimateFontSize(bounds: bounds, sampleText: raw)
        let isBold = estimateBold(bounds: bounds, sampleText: raw, fontSize: fontSize)
        return Selection(pageIndex: pageIndex, bounds: bounds, text: raw, fontSize: fontSize, isBold: isBold)
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

    // MARK: - Replace (matched size, single paint pass per page)

    @discardableResult
    public static func coverAndReplace(
        on page: PDFPage,
        bounds: CGRect,
        newText: String,
        originalText: String = ""
    ) -> Bool {
        applyReplacements(on: page, ops: [
            ReplaceOp(bounds: bounds, originalText: originalText.isEmpty ? newText : originalText, newText: newText)
        ])
    }

    /// Apply many replacements on one page in a single high-quality rasterize (avoids cascading damage).
    @discardableResult
    public static func applyReplacements(on page: PDFPage, ops: [ReplaceOp]) -> Bool {
        guard !ops.isEmpty, let document = page.document else { return false }
        let pageIndex = document.index(for: page)
        guard pageIndex != NSNotFound else { return false }

        let media = page.bounds(for: .mediaBox)
        let scale: CGFloat = 3.0 // sharper for titles
        let pxW = max(1, Int(ceil(media.width * scale)))
        let pxH = max(1, Int(ceil(media.height * scale)))

        guard let ctx = CGContext(
            data: nil,
            width: pxW,
            height: pxH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }

        // White + draw original page (PDF space bottom-left)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: pxW, height: pxH))
        ctx.saveGState()
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: ctx)
        ctx.restoreGState()

        for op in ops {
            guard !op.bounds.isNull, op.bounds.width > 0.5, op.bounds.height > 0.5 else { continue }
            let fontSize = estimateFontSize(bounds: op.bounds, sampleText: op.originalText)
            let isBold = estimateBold(bounds: op.bounds, sampleText: op.originalText, fontSize: fontSize)
            let font = preferredCTFont(size: fontSize, bold: isBold)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font as CTFont,
                .foregroundColor: CGColor(gray: 0.05, alpha: 1)
            ]
            let attr = NSAttributedString(string: op.newText, attributes: attrs)
            let line = CTLineCreateWithAttributedString(attr)
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let lineWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            let lineHeight = ascent + descent

            // Cover slightly larger than original run
            let padX: CGFloat = 1.0
            let padY: CGFloat = 0.5
            let cover = op.bounds.insetBy(dx: -padX, dy: -padY)
            // Expand cover to fit longer replacement
            let neededW = max(cover.width, lineWidth + padX * 2)
            let coverRect = CGRect(
                x: cover.minX,
                y: cover.minY,
                width: neededW,
                height: max(cover.height, lineHeight + padY)
            )

            // White-out in device pixels
            let dev = CGRect(
                x: coverRect.minX * scale,
                y: coverRect.minY * scale,
                width: coverRect.width * scale,
                height: coverRect.height * scale
            )
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(dev.insetBy(dx: -0.5 * scale, dy: -0.5 * scale))

            // Draw text in point space, then scale into device pixels (no Y-flip issues).
            let baseline = op.bounds.minY + (op.bounds.height - lineHeight) / 2 + descent
            ctx.saveGState()
            ctx.translateBy(x: op.bounds.minX * scale, y: baseline * scale)
            ctx.scaleBy(x: scale, y: scale)
            ctx.textMatrix = .identity
            ctx.textPosition = .zero
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }

        guard let cgImage = ctx.makeImage() else { return false }
        let outImage = NSImage(cgImage: cgImage, size: NSSize(width: media.width, height: media.height))
        guard let newPage = PDFPage(image: outImage) else { return false }
        newPage.rotation = page.rotation
        document.removePage(at: pageIndex)
        document.insert(newPage, at: pageIndex)
        return true
    }

    public static func replaceAll(
        in document: PDFDocument,
        query: String,
        replacement: String,
        caseSensitive: Bool
    ) -> Int {
        let hits = findMatches(in: document, query: query, caseSensitive: caseSensitive)
        guard !hits.isEmpty else { return 0 }

        // Group by page — one paint per page
        var byPage: [Int: [ReplaceOp]] = [:]
        for hit in hits {
            byPage[hit.pageIndex, default: []].append(
                ReplaceOp(bounds: hit.bounds, originalText: hit.text, newText: replacement)
            )
        }
        for (pageIndex, ops) in byPage.sorted(by: { $0.key > $1.key }) {
            guard let page = document.page(at: pageIndex) else { continue }
            // Apply bottom-to-top within page so any tiny overlaps are safer
            let ordered = ops.sorted { $0.bounds.minY > $1.bounds.minY }
            _ = applyReplacements(on: page, ops: ordered)
        }
        return hits.count
    }

    // MARK: - Markup (selection only — Pages/Canva: drag then highlight)

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
                // Tight highlight around glyphs — do NOT wildly inflate
                if type == .highlight {
                    bounds = bounds.insetBy(dx: 0, dy: -0.6)
                }
                let ann = PDFAnnotation(bounds: bounds, forType: type, withProperties: nil)
                // PDFKit highlight multiplies with yellow — keep alpha moderate
                if type == .highlight {
                    ann.color = NSColor(calibratedRed: 1, green: 0.92, blue: 0.2, alpha: 1)
                } else {
                    ann.color = color
                }
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
        // Build a temporary PDFSelection from string range is hard; use tight bounds
        var bounds = sel.bounds
        if type == .highlight {
            bounds = bounds.insetBy(dx: 0, dy: -0.6)
        }
        let ann = PDFAnnotation(bounds: bounds, forType: type, withProperties: nil)
        if type == .highlight {
            ann.color = NSColor(calibratedRed: 1, green: 0.92, blue: 0.2, alpha: 1)
        } else {
            ann.color = color
        }
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
        // PDF glyph box height is close to em-box; for large titles this is critical.
        let byHeight = bounds.height * 0.88
        if sampleText.count >= 2, bounds.width > 1 {
            let avgAdvance = bounds.width / CGFloat(max(1, sampleText.count))
            // Helvetica-ish aspect
            let byWidth = avgAdvance * 1.55
            // Prefer height for titles (more stable)
            let blended = byHeight * 0.85 + min(byHeight * 1.15, byWidth) * 0.15
            return max(7, min(96, blended))
        }
        return max(7, min(96, byHeight))
    }

    public static func estimateBold(bounds: CGRect, sampleText: String, fontSize: CGFloat) -> Bool {
        // Large display text / short wide runs tend to be bold headings
        if fontSize >= 18 { return true }
        guard sampleText.count >= 2 else { return fontSize >= 14 }
        let avgAdvance = bounds.width / CGFloat(sampleText.count)
        // Bold advances are slightly wider; also title case short words
        return avgAdvance > fontSize * 0.58 || fontSize >= 16
    }

    // MARK: - Private

    private static func preferredCTFont(size: CGFloat, bold: Bool) -> CTFont {
        let name = bold ? "Helvetica-Bold" : "Helvetica"
        return CTFontCreateWithName(name as CFString, size, nil)
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
        let fontSize = estimateFontSize(bounds: bounds, sampleText: raw)
        return Selection(
            pageIndex: pageIndex,
            bounds: bounds,
            text: raw,
            fontSize: fontSize,
            isBold: estimateBold(bounds: bounds, sampleText: raw, fontSize: fontSize)
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
                let fontSize = estimateFontSize(bounds: bounds, sampleText: ch)
                return Selection(pageIndex: pageIndex, bounds: bounds, text: ch, fontSize: fontSize, isBold: fontSize >= 16)
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
