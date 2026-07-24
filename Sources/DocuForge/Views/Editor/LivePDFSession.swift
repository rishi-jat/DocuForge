import Foundation
import AppKit
import PDFKit
import DocuForgeCore

/// Shared live PDF document for on-canvas editing (Canva / iLovePDF style).
@MainActor
final class LivePDFSession: ObservableObject {
    enum Tool: String, CaseIterable, Identifiable {
        case select
        case text
        case highlight
        case signature
        case screenshot

        var id: String { rawValue }

        var title: String {
            switch self {
            case .select: return "Select"
            case .text: return "Text"
            case .highlight: return "Highlight"
            case .signature: return "Sign"
            case .screenshot: return "Screenshot"
            }
        }

        var systemImage: String {
            switch self {
            case .select: return "cursorarrow"
            case .text: return "text.cursor"
            case .highlight: return "highlighter"
            case .signature: return "signature"
            case .screenshot: return "camera.viewfinder"
            }
        }
    }

    let document: PDFDocument
    private(set) var sourceURL: URL

    @Published var tool: Tool = .select
    @Published var currentPageIndex: Int = 0
    @Published var isDirty: Bool = false
    @Published var status: String = ""
    @Published var findQuery: String = ""
    @Published var replaceQuery: String = ""
    @Published var caseSensitive: Bool = false
    @Published var matchCount: Int = 0
    @Published var findIndex: Int = 0
    @Published var textBoxDraft: String = "Text"
    @Published var pageImageForEdit: NSImage?
    @Published var showPageImageEditor: Bool = false

    /// Find hits as page index + bounds (page space).
    private(set) var findHits: [(page: Int, bounds: CGRect)] = []

    init(document: PDFDocument, sourceURL: URL) {
        self.document = document
        self.sourceURL = sourceURL
    }

    static func open(url: URL) throws -> LivePDFSession {
        guard let doc = PDFDocument(url: url) else {
            throw DocuForgeError.pdfOperationFailed("Could not open \(url.lastPathComponent)")
        }
        if doc.isLocked {
            throw DocuForgeError.invalidInput("PDF is password-locked. Unlock it first.")
        }
        return LivePDFSession(document: doc, sourceURL: url)
    }

    var pageCount: Int { document.pageCount }

    func goToPage(_ index: Int) {
        guard index >= 0, index < document.pageCount else { return }
        currentPageIndex = index
    }

    // MARK: - Find / replace (layout-preserving)

    func refreshFind() {
        findHits = []
        findIndex = 0
        matchCount = 0
        let q = findQuery
        guard !q.isEmpty, document.pageCount > 0 else { return }

        var options: NSString.CompareOptions = []
        if !caseSensitive { options.insert(.caseInsensitive) }

        // Search page by page for stable bounds
        for i in 0..<document.pageCount {
            guard let page = document.page(at: i), let pageText = page.string as NSString? else { continue }
            var searchRange = NSRange(location: 0, length: pageText.length)
            while searchRange.length > 0 {
                let found = pageText.range(of: q, options: options, range: searchRange)
                if found.location == NSNotFound { break }
                // Map string range → page selection bounds (keeps coordinates for cover-up replace)
                if let selection = document.selection(
                    from: page,
                    atCharacterIndex: found.location,
                    to: page,
                    atCharacterIndex: max(found.location, NSMaxRange(found) - 1)
                ) {
                    let bounds = selection.bounds(for: page)
                    if !bounds.isNull, bounds.width > 0, bounds.height > 0 {
                        findHits.append((page: i, bounds: bounds))
                    }
                }
                let next = found.location + max(found.length, 1)
                if next >= pageText.length { break }
                searchRange = NSRange(location: next, length: pageText.length - next)
            }
        }
        matchCount = findHits.count
        status = matchCount == 0 ? "No matches for “\(q)”." : "\(matchCount) match\(matchCount == 1 ? "" : "es") found."
    }

    /// Replace every match by covering original glyphs and drawing replacement text.
    /// Keeps page graphics/layout; only the matched runs are overpainted.
    func replaceAllPreservingLayout() {
        refreshFind()
        guard !findHits.isEmpty else {
            status = "Nothing to replace."
            return
        }
        let replacement = replaceQuery
        for hit in findHits.reversed() {
            guard let page = document.page(at: hit.page) else { continue }
            let bounds = hit.bounds.insetBy(dx: -1, dy: -1)

            // Cover old text (layout of rest of page stays)
            let cover = PDFAnnotation(bounds: bounds, forType: .square, withProperties: nil)
            cover.color = .clear
            cover.interiorColor = NSColor.white
            cover.border = PDFBorder()
            cover.border?.lineWidth = 0
            page.addAnnotation(cover)

            // New text in the same box
            let box = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
            box.contents = replacement
            let fontSize = max(8, min(28, bounds.height * 0.85))
            box.font = NSFont.systemFont(ofSize: fontSize)
            box.fontColor = .black
            box.color = .clear
            box.alignment = .left
            page.addAnnotation(box)
        }
        let n = findHits.count
        isDirty = true
        findHits = []
        matchCount = 0
        status = "Replaced \(n) occurrence(s) without rebuilding the PDF layout."
        objectWillChange.send()
    }

    func goToNextMatch(in pdfView: PDFView?) {
        guard !findHits.isEmpty else { return }
        findIndex = (findIndex + 1) % findHits.count
        let hit = findHits[findIndex]
        currentPageIndex = hit.page
        if let page = document.page(at: hit.page), let pdfView {
            pdfView.go(to: page)
            // Brief highlight
            let flash = PDFAnnotation(bounds: hit.bounds, forType: .highlight, withProperties: nil)
            flash.color = NSColor.systemYellow.withAlphaComponent(0.45)
            page.addAnnotation(flash)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                page.removeAnnotation(flash)
            }
        }
        status = "Match \(findIndex + 1) of \(findHits.count)"
    }

    // MARK: - Canvas tools

    func handleClick(page: PDFPage, pointInPage: CGPoint) {
        let pageIndex = document.index(for: page)
        if pageIndex != NSNotFound { currentPageIndex = pageIndex }

        switch tool {
        case .select:
            break
        case .text:
            let size = CGSize(width: 180, height: 28)
            let rect = CGRect(
                x: pointInPage.x,
                y: pointInPage.y - size.height / 2,
                width: size.width,
                height: size.height
            )
            let ann = PDFAnnotation(bounds: rect, forType: .freeText, withProperties: nil)
            ann.contents = textBoxDraft.isEmpty ? "Text" : textBoxDraft
            ann.font = NSFont.systemFont(ofSize: 14)
            ann.fontColor = .black
            ann.color = NSColor.white.withAlphaComponent(0.01)
            page.addAnnotation(ann)
            isDirty = true
            status = "Added text box. Double-click it in the viewer to edit."
            objectWillChange.send()
        case .highlight:
            let rect = CGRect(x: pointInPage.x - 60, y: pointInPage.y - 10, width: 120, height: 18)
            let ann = PDFAnnotation(bounds: rect, forType: .highlight, withProperties: nil)
            ann.color = NSColor.systemYellow.withAlphaComponent(0.45)
            page.addAnnotation(ann)
            isDirty = true
            status = "Added highlight."
            objectWillChange.send()
        case .signature:
            let rect = CGRect(x: pointInPage.x - 80, y: pointInPage.y - 20, width: 160, height: 40)
            let ann = PDFAnnotation(bounds: rect, forType: .ink, withProperties: nil)
            ann.color = .black
            let path = NSBezierPath()
            path.move(to: CGPoint(x: 4, y: 20))
            path.curve(
                to: CGPoint(x: 156, y: 20),
                controlPoint1: CGPoint(x: 40, y: 36),
                controlPoint2: CGPoint(x: 120, y: 4)
            )
            ann.add(path)
            page.addAnnotation(ann)
            isDirty = true
            status = "Added signature stroke."
            objectWillChange.send()
        case .screenshot:
            // Click means "edit this page's visual as image"
            beginEditPageAsImage()
        }
    }

    // MARK: - Screenshots / page images (format of PDF preserved)

    func beginEditPageAsImage() {
        guard let page = document.page(at: currentPageIndex) else { return }
        pageImageForEdit = render(page: page, dpi: 144)
        showPageImageEditor = true
        status = "Edit the page image, then Apply to replace this page only. Other pages stay unchanged."
    }

    func applyEditedPageImage(_ image: NSImage) {
        guard let newPage = PDFPage(image: image) else {
            status = "Could not create page from edited image."
            return
        }
        if let old = document.page(at: currentPageIndex) {
            newPage.rotation = old.rotation
        }
        document.removePage(at: currentPageIndex)
        document.insert(newPage, at: currentPageIndex)
        isDirty = true
        showPageImageEditor = false
        pageImageForEdit = nil
        status = "Page \(currentPageIndex + 1) updated. PDF structure of other pages is unchanged."
        objectWillChange.send()
    }

    func pasteScreenshotReplacingPage() {
        guard let image = NSImage(pasteboard: .general) ?? pasteboardImage() else {
            status = "Clipboard has no image. Capture with ⌘⇧4, copy, then paste."
            return
        }
        applyEditedPageImage(image)
        status = "Replaced page \(currentPageIndex + 1) with clipboard screenshot."
    }

    func pasteScreenshotAsNewPage() {
        guard let image = NSImage(pasteboard: .general) ?? pasteboardImage() else {
            status = "Clipboard has no image."
            return
        }
        guard let newPage = PDFPage(image: image) else { return }
        let at = min(currentPageIndex + 1, document.pageCount)
        document.insert(newPage, at: at)
        currentPageIndex = at
        isDirty = true
        status = "Inserted screenshot as page \(at + 1)."
        objectWillChange.send()
    }

    func rotateCurrentPage(_ degrees: Int) {
        guard let page = document.page(at: currentPageIndex) else { return }
        page.rotation = (page.rotation + degrees) % 360
        if page.rotation < 0 { page.rotation += 360 }
        isDirty = true
        status = "Rotated page \(currentPageIndex + 1)."
        objectWillChange.send()
    }

    func deleteCurrentPage() {
        guard document.pageCount > 1 else {
            status = "Cannot delete the only page."
            return
        }
        document.removePage(at: currentPageIndex)
        if currentPageIndex >= document.pageCount {
            currentPageIndex = document.pageCount - 1
        }
        isDirty = true
        status = "Deleted page."
        objectWillChange.send()
    }

    // MARK: - Save

    @discardableResult
    func save(to url: URL? = nil) throws -> URL {
        let target = url ?? sourceURL
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("docuforge-edit-\(UUID().uuidString).pdf")
        guard document.write(to: temp) else {
            throw DocuForgeError.pdfOperationFailed("Failed to write PDF.")
        }
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.copyItem(at: temp, to: target)
        try? FileManager.default.removeItem(at: temp)
        sourceURL = target
        isDirty = false
        status = "Saved \(target.lastPathComponent) — format remains PDF."
        return target
    }

    // MARK: - Helpers

    private func pasteboardImage() -> NSImage? {
        let pb = NSPasteboard.general
        if let data = pb.data(forType: .png) ?? pb.data(forType: .tiff) {
            return NSImage(data: data)
        }
        return nil
    }

    private func render(page: PDFPage, dpi: CGFloat) -> NSImage {
        let bounds = page.bounds(for: .mediaBox)
        let scale = dpi / 72.0
        let size = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        let image = NSImage(size: size)
        image.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.saveGState()
            ctx.scaleBy(x: scale, y: scale)
            page.draw(with: .mediaBox, to: ctx)
            ctx.restoreGState()
        }
        image.unlockFocus()
        return image
    }
}
