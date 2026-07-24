import Foundation
import AppKit
import PDFKit

/// Layout-preserving PDF text find / click-select / cover-replace.
/// Shared by the live canvas and automated tests — this is the real logic.
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

        public init(pageIndex: Int, bounds: CGRect, text: String) {
            self.pageIndex = pageIndex
            self.bounds = bounds
            self.text = text
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

                let endIndex = max(found.location, NSMaxRange(found) - 1)
                if let selection = document.selection(
                    from: page,
                    atCharacterIndex: found.location,
                    to: page,
                    atCharacterIndex: endIndex
                ) {
                    let bounds = selection.bounds(for: page)
                    if !bounds.isNull, bounds.width > 0.2, bounds.height > 0.2 {
                        let matched = pageText.substring(with: found)
                        hits.append(Match(pageIndex: i, bounds: bounds, text: matched))
                    }
                } else {
                    // Fallback: approximate using character bounds if available
                    if let approx = approximateBounds(page: page, range: found) {
                        let matched = pageText.substring(with: found)
                        hits.append(Match(pageIndex: i, bounds: approx, text: matched))
                    }
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
        // 1) Direct word/line under cursor
        if preferLine {
            if let s = usableSelection(page.selectionForLine(at: point), page: page) {
                return Selection(pageIndex: pageIndex, bounds: s.bounds, text: s.text)
            }
        }
        if let s = usableSelection(page.selectionForWord(at: point), page: page) {
            return Selection(pageIndex: pageIndex, bounds: s.bounds, text: s.text)
        }
        if !preferLine, let s = usableSelection(page.selectionForLine(at: point), page: page) {
            return Selection(pageIndex: pageIndex, bounds: s.bounds, text: s.text)
        }

        // 2) characterIndex at point
        let idx = page.characterIndex(at: point)
        if idx != NSNotFound, let s = selectionAroundCharacter(page: page, index: idx, preferLine: preferLine) {
            return Selection(pageIndex: pageIndex, bounds: s.bounds, text: s.text)
        }

        // 3) Spiral search around the click (users rarely hit exact glyph pixels)
        let radii: [CGFloat] = [2, 4, 8, 12, 18, 28, 40]
        for r in radii {
            for angle in stride(from: 0.0, to: 360.0, by: 45.0) {
                let rad = angle * .pi / 180
                let p = CGPoint(x: point.x + r * cos(rad), y: point.y + r * sin(rad))
                if let s = usableSelection(page.selectionForWord(at: p), page: page) {
                    return Selection(pageIndex: pageIndex, bounds: s.bounds, text: s.text)
                }
                let cidx = page.characterIndex(at: p)
                if cidx != NSNotFound, let s = selectionAroundCharacter(page: page, index: cidx, preferLine: preferLine) {
                    return Selection(pageIndex: pageIndex, bounds: s.bounds, text: s.text)
                }
            }
        }
        return nil
    }

    // MARK: - Apply cover + text

    @discardableResult
    public static func coverAndReplace(
        on page: PDFPage,
        bounds: CGRect,
        newText: String
    ) -> Bool {
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return false }
        let pad = bounds.insetBy(dx: -2, dy: -1.5)

        let cover = PDFAnnotation(bounds: pad, forType: .square, withProperties: nil)
        cover.color = NSColor.white
        cover.interiorColor = NSColor.white
        cover.border = PDFBorder()
        cover.border?.lineWidth = 0
        cover.shouldDisplay = true
        cover.shouldPrint = true
        page.addAnnotation(cover)

        let box = PDFAnnotation(bounds: pad, forType: .freeText, withProperties: nil)
        box.contents = newText
        let fontSize = max(7, min(36, pad.height * 0.78))
        box.font = NSFont.systemFont(ofSize: fontSize)
        box.fontColor = .black
        box.color = .clear
        box.alignment = .left
        box.shouldDisplay = true
        box.shouldPrint = true
        page.addAnnotation(box)
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
        // Apply from end so bounds remain valid
        for hit in hits.reversed() {
            guard let page = document.page(at: hit.pageIndex) else { continue }
            _ = coverAndReplace(on: page, bounds: hit.bounds, newText: replacement)
        }
        return hits.count
    }

    public static func pageHasExtractableText(_ page: PDFPage) -> Bool {
        guard let s = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return !s.isEmpty
    }

    // MARK: - Private helpers

    private struct Usable {
        let bounds: CGRect
        let text: String
    }

    private static func usableSelection(_ selection: PDFSelection?, page: PDFPage) -> Usable? {
        guard let selection,
              let raw = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        let bounds = selection.bounds(for: page)
        guard !bounds.isNull, bounds.width > 0.4, bounds.height > 0.4 else { return nil }
        return Usable(bounds: bounds, text: raw)
    }

    private static func selectionAroundCharacter(
        page: PDFPage,
        index: Int,
        preferLine: Bool
    ) -> Usable? {
        // characterIndex is 0-based into page.string
        guard let pageText = page.string as NSString?, index >= 0, index < pageText.length else {
            return nil
        }
        let point = page.characterBounds(at: index).origin
        if preferLine {
            if let s = usableSelection(page.selectionForLine(at: point), page: page) { return s }
        }
        if let s = usableSelection(page.selectionForWord(at: point), page: page) { return s }
        // Single character fallback
        let bounds = page.characterBounds(at: index)
        if !bounds.isNull, bounds.width > 0, bounds.height > 0 {
            let ch = pageText.substring(with: NSRange(location: index, length: 1))
            if !ch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return Usable(bounds: bounds, text: ch)
            }
        }
        return nil
    }

    private static func approximateBounds(page: PDFPage, range: NSRange) -> CGRect? {
        guard range.location != NSNotFound, range.length > 0 else { return nil }
        var union = CGRect.null
        let end = NSMaxRange(range)
        for i in range.location..<end {
            let b = page.characterBounds(at: i)
            if !b.isNull { union = union.union(b) }
        }
        if union.isNull || union.width < 0.2 { return nil }
        return union
    }
}
