import Foundation
import AppKit
import PDFKit
import DocuForgeCore

/// Shared live PDF document for on-canvas editing (Canva / iLovePDF style).
@MainActor
final class LivePDFSession: ObservableObject {
    enum Tool: String, CaseIterable, Identifiable {
        case select
        case editText
        case addText
        case highlight
        case underline
        case strike
        case signature
        case stamp
        case screenshot

        var id: String { rawValue }

        var title: String {
            switch self {
            case .select: return "Select"
            case .editText: return "Edit word"
            case .addText: return "Add text"
            case .highlight: return "Highlight"
            case .underline: return "Underline"
            case .strike: return "Strike"
            case .signature: return "Sign"
            case .stamp: return "Stamp"
            case .screenshot: return "Screenshot"
            }
        }

        var shortTitle: String {
            switch self {
            case .select: return "Select"
            case .editText: return "Edit"
            case .addText: return "Text+"
            case .highlight: return "HL"
            case .underline: return "U"
            case .strike: return "S"
            case .signature: return "Sign"
            case .stamp: return "Stamp"
            case .screenshot: return "Shot"
            }
        }

        var systemImage: String {
            switch self {
            case .select: return "cursorarrow"
            case .editText: return "character.cursor.ibeam"
            case .addText: return "text.badge.plus"
            case .highlight: return "highlighter"
            case .underline: return "underline"
            case .strike: return "strikethrough"
            case .signature: return "signature"
            case .stamp: return "seal"
            case .screenshot: return "camera.viewfinder"
            }
        }
    }

    enum TextPickMode: String, CaseIterable, Identifiable {
        case word
        case line

        var id: String { rawValue }
        var title: String {
            switch self {
            case .word: return "Word"
            case .line: return "Line"
            }
        }
    }

    /// A selected run of existing PDF text ready for layout-preserving edit.
    struct TextSelectionHit: Equatable {
        var pageIndex: Int
        var bounds: CGRect
        var originalText: String
    }

    let document: PDFDocument
    private(set) var sourceURL: URL

    @Published var tool: Tool = .editText
    @Published var currentPageIndex: Int = 0
    @Published var isDirty: Bool = false
    @Published var status: String = ""
    @Published var findQuery: String = ""
    @Published var replaceQuery: String = ""
    @Published var caseSensitive: Bool = false
    @Published var matchCount: Int = 0
    @Published var findIndex: Int = 0
    @Published var textBoxDraft: String = "New text"
    @Published var stampDraft: String = "APPROVED"
    @Published var pageImageForEdit: NSImage?
    @Published var showPageImageEditor: Bool = false

    /// Click-to-edit selection (existing PDF words)
    @Published var textPickMode: TextPickMode = .word
    @Published var selectedHit: TextSelectionHit?
    @Published var editDraft: String = ""
    @Published var selectionFlashToken: Int = 0

    /// Find hits as page index + bounds (page space).
    private(set) var findHits: [(page: Int, bounds: CGRect)] = []

    /// Temporary yellow highlight for the active text selection.
    private weak var selectionFlashAnnotation: PDFAnnotation?
    private weak var selectionFlashPage: PDFPage?

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

    var hasActiveTextEdit: Bool {
        selectedHit != nil && !editDraft.isEmpty
    }

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

        for i in 0..<document.pageCount {
            guard let page = document.page(at: i), let pageText = page.string as NSString? else { continue }
            var searchRange = NSRange(location: 0, length: pageText.length)
            while searchRange.length > 0 {
                let found = pageText.range(of: q, options: options, range: searchRange)
                if found.location == NSNotFound { break }
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
    func replaceAllPreservingLayout() {
        refreshFind()
        guard !findHits.isEmpty else {
            status = "Nothing to replace."
            return
        }
        let replacement = replaceQuery
        for hit in findHits.reversed() {
            guard let page = document.page(at: hit.page) else { continue }
            applyCoverAndText(on: page, bounds: hit.bounds, text: replacement)
        }
        let n = findHits.count
        isDirty = true
        findHits = []
        matchCount = 0
        clearTextSelection()
        status = "Replaced \(n) occurrence(s). Layout of the rest of the page is unchanged."
        objectWillChange.send()
    }

    func goToNextMatch(in pdfView: PDFView?) {
        guard !findHits.isEmpty else { return }
        findIndex = (findIndex + 1) % findHits.count
        let hit = findHits[findIndex]
        currentPageIndex = hit.page
        if let page = document.page(at: hit.page), let pdfView {
            pdfView.go(to: page)
            flashBounds(hit.bounds, on: page, color: NSColor.systemYellow.withAlphaComponent(0.45), seconds: 0.8)
        }
        status = "Match \(findIndex + 1) of \(findHits.count)"
    }

    // MARK: - Click-to-edit existing PDF text

    /// Select word or line under click so the user can change existing PDF text.
    func selectTextAt(page: PDFPage, pointInPage: CGPoint) {
        let pageIndex = document.index(for: page)
        if pageIndex != NSNotFound { currentPageIndex = pageIndex }

        let selection: PDFSelection?
        switch textPickMode {
        case .word:
            selection = page.selectionForWord(at: pointInPage)
        case .line:
            selection = page.selectionForLine(at: pointInPage)
        }

        guard let selection,
              let raw = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            clearTextSelection()
            status = "No text under the click. Try a word, or switch to Line pick."
            return
        }

        let bounds = selection.bounds(for: page)
        guard !bounds.isNull, bounds.width > 0.5, bounds.height > 0.5 else {
            clearTextSelection()
            status = "Could not locate text bounds. Try Find → Replace All instead."
            return
        }

        selectedHit = TextSelectionHit(
            pageIndex: pageIndex == NSNotFound ? currentPageIndex : pageIndex,
            bounds: bounds,
            originalText: raw
        )
        editDraft = raw
        selectionFlashToken &+= 1
        flashSelection(on: page, bounds: bounds)
        status = "Selected “\(shortPreview(raw))”. Change it below, then Apply."
        objectWillChange.send()
    }

    /// Apply the edit draft over the selected existing text (cover + freeText).
    func applySelectedTextEdit() {
        guard let hit = selectedHit else {
            status = "Click a word on the page first (Edit word tool)."
            return
        }
        let newText = editDraft
        guard !newText.isEmpty else {
            status = "Replacement text cannot be empty."
            return
        }
        guard let page = document.page(at: hit.pageIndex) else {
            status = "Page no longer available."
            clearTextSelection()
            return
        }

        clearFlash()
        applyCoverAndText(on: page, bounds: hit.bounds, text: newText)
        isDirty = true
        let old = hit.originalText
        clearTextSelection()
        status = "Changed “\(shortPreview(old))” → “\(shortPreview(newText))”. Rest of the page layout is kept."
        objectWillChange.send()
    }

    /// Cover selected text without writing replacement (blank-out).
    func eraseSelectedText() {
        guard let hit = selectedHit,
              let page = document.page(at: hit.pageIndex) else {
            status = "Select text first."
            return
        }
        clearFlash()
        let bounds = hit.bounds.insetBy(dx: -1.5, dy: -1.0)
        let cover = PDFAnnotation(bounds: bounds, forType: .square, withProperties: nil)
        cover.color = .clear
        cover.interiorColor = .white
        cover.border = PDFBorder()
        cover.border?.lineWidth = 0
        page.addAnnotation(cover)
        isDirty = true
        clearTextSelection()
        status = "Covered selected text (layout preserved)."
        objectWillChange.send()
    }

    func clearTextSelection() {
        clearFlash()
        selectedHit = nil
        editDraft = ""
        objectWillChange.send()
    }

    // MARK: - Canvas tools

    func handleClick(page: PDFPage, pointInPage: CGPoint) {
        let pageIndex = document.index(for: page)
        if pageIndex != NSNotFound { currentPageIndex = pageIndex }

        switch tool {
        case .select:
            break
        case .editText:
            selectTextAt(page: page, pointInPage: pointInPage)
        case .addText:
            addFreeText(page: page, at: pointInPage, text: textBoxDraft.isEmpty ? "Text" : textBoxDraft)
        case .highlight:
            // Prefer highlight over word under click if text exists
            if let sel = page.selectionForWord(at: pointInPage),
               let s = sel.string, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let bounds = sel.bounds(for: page).insetBy(dx: -1, dy: -1)
                addAnnotation(type: .highlight, page: page, bounds: bounds, color: NSColor.systemYellow.withAlphaComponent(0.45))
                status = "Highlighted “\(shortPreview(s))”."
            } else {
                let rect = CGRect(x: pointInPage.x - 60, y: pointInPage.y - 10, width: 120, height: 18)
                addAnnotation(type: .highlight, page: page, bounds: rect, color: NSColor.systemYellow.withAlphaComponent(0.45))
                status = "Added highlight band."
            }
        case .underline:
            if let sel = page.selectionForWord(at: pointInPage) ?? page.selectionForLine(at: pointInPage),
               let s = sel.string, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let bounds = sel.bounds(for: page)
                addAnnotation(type: .underline, page: page, bounds: bounds, color: .systemBlue)
                status = "Underlined “\(shortPreview(s))”."
            } else {
                let rect = CGRect(x: pointInPage.x - 50, y: pointInPage.y - 4, width: 100, height: 14)
                addAnnotation(type: .underline, page: page, bounds: rect, color: .systemBlue)
                status = "Added underline."
            }
        case .strike:
            if let sel = page.selectionForWord(at: pointInPage) ?? page.selectionForLine(at: pointInPage),
               let s = sel.string, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let bounds = sel.bounds(for: page)
                addAnnotation(type: .strikeOut, page: page, bounds: bounds, color: .systemRed)
                status = "Struck “\(shortPreview(s))”."
            } else {
                let rect = CGRect(x: pointInPage.x - 50, y: pointInPage.y - 4, width: 100, height: 14)
                addAnnotation(type: .strikeOut, page: page, bounds: rect, color: .systemRed)
                status = "Added strikethrough."
            }
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
        case .stamp:
            let text = stampDraft.isEmpty ? "APPROVED" : stampDraft
            let width = max(100, CGFloat(text.count) * 10)
            let rect = CGRect(x: pointInPage.x - width / 2, y: pointInPage.y - 16, width: width, height: 32)
            let ann = PDFAnnotation(bounds: rect, forType: .stamp, withProperties: nil)
            ann.contents = text
            ann.color = NSColor.systemRed.withAlphaComponent(0.85)
            page.addAnnotation(ann)
            // Also freeText so stamp is readable everywhere
            let box = PDFAnnotation(bounds: rect, forType: .freeText, withProperties: nil)
            box.contents = text
            box.font = NSFont.boldSystemFont(ofSize: 14)
            box.fontColor = .systemRed
            box.color = NSColor.white.withAlphaComponent(0.15)
            box.alignment = .center
            page.addAnnotation(box)
            isDirty = true
            status = "Stamped “\(text)”."
            objectWillChange.send()
        case .screenshot:
            beginEditPageAsImage()
        }
    }

    // MARK: - Screenshots / page images (PDF format preserved)

    func beginEditPageAsImage() {
        guard let page = document.page(at: currentPageIndex) else { return }
        pageImageForEdit = render(page: page, dpi: 144)
        showPageImageEditor = true
        status = "Screenshot editor: adjust this page as an image. Apply replaces only this page — other pages stay as original PDF."
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
        status = "Page \(currentPageIndex + 1) updated from screenshot edit. File stays PDF; other pages unchanged."
        objectWillChange.send()
    }

    func pasteScreenshotReplacingPage() {
        guard let image = NSImage(pasteboard: .general) ?? pasteboardImage() else {
            status = "Clipboard has no image. Capture with ⌘⇧4, then copy, then Paste screenshot."
            return
        }
        applyEditedPageImage(image)
        status = "Replaced page \(currentPageIndex + 1) with clipboard screenshot. Document remains PDF."
    }

    func pasteScreenshotAsNewPage() {
        guard let image = NSImage(pasteboard: .general) ?? pasteboardImage() else {
            status = "Clipboard has no image. Capture with ⌘⇧4 first."
            return
        }
        guard let newPage = PDFPage(image: image) else { return }
        let at = min(currentPageIndex + 1, document.pageCount)
        document.insert(newPage, at: at)
        currentPageIndex = at
        isDirty = true
        status = "Inserted screenshot as new PDF page \(at + 1). Format remains PDF."
        objectWillChange.send()
    }

    func insertBlankPage() {
        let size: CGSize
        if let page = document.page(at: currentPageIndex) {
            size = page.bounds(for: .mediaBox).size
        } else {
            size = CGSize(width: 612, height: 792)
        }
        let blank = PDFPage()
        blank.setBounds(CGRect(origin: .zero, size: size), for: .mediaBox)
        let at = min(currentPageIndex + 1, document.pageCount)
        document.insert(blank, at: at)
        currentPageIndex = at
        isDirty = true
        status = "Inserted blank page \(at + 1)."
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
        clearTextSelection()
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

    private func addFreeText(page: PDFPage, at point: CGPoint, text: String) {
        let size = CGSize(width: max(160, CGFloat(text.count) * 8), height: 28)
        let rect = CGRect(
            x: point.x,
            y: point.y - size.height / 2,
            width: size.width,
            height: size.height
        )
        let ann = PDFAnnotation(bounds: rect, forType: .freeText, withProperties: nil)
        ann.contents = text
        ann.font = NSFont.systemFont(ofSize: 14)
        ann.fontColor = .black
        ann.color = NSColor.white.withAlphaComponent(0.01)
        page.addAnnotation(ann)
        isDirty = true
        status = "Added text box “\(shortPreview(text))”. Use Edit word to change existing PDF text."
        objectWillChange.send()
    }

    private func addAnnotation(type: PDFAnnotationSubtype, page: PDFPage, bounds: CGRect, color: NSColor) {
        let ann = PDFAnnotation(bounds: bounds, forType: type, withProperties: nil)
        ann.color = color
        page.addAnnotation(ann)
        isDirty = true
        objectWillChange.send()
    }

    /// White cover + freeText replacement in the same bounds (layout-preserving word change).
    private func applyCoverAndText(on page: PDFPage, bounds: CGRect, text: String) {
        let pad = bounds.insetBy(dx: -1.5, dy: -1.0)

        let cover = PDFAnnotation(bounds: pad, forType: .square, withProperties: nil)
        cover.color = .clear
        cover.interiorColor = .white
        cover.border = PDFBorder()
        cover.border?.lineWidth = 0
        page.addAnnotation(cover)

        let box = PDFAnnotation(bounds: pad, forType: .freeText, withProperties: nil)
        box.contents = text
        let fontSize = max(7, min(32, pad.height * 0.82))
        box.font = NSFont.systemFont(ofSize: fontSize)
        box.fontColor = .black
        box.color = .clear
        box.alignment = .left
        page.addAnnotation(box)
    }

    private func flashSelection(on page: PDFPage, bounds: CGRect) {
        clearFlash()
        let flash = PDFAnnotation(bounds: bounds.insetBy(dx: -2, dy: -2), forType: .highlight, withProperties: nil)
        flash.color = NSColor.systemBlue.withAlphaComponent(0.35)
        page.addAnnotation(flash)
        selectionFlashAnnotation = flash
        selectionFlashPage = page
    }

    private func flashBounds(_ bounds: CGRect, on page: PDFPage, color: NSColor, seconds: TimeInterval) {
        let flash = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
        flash.color = color
        page.addAnnotation(flash)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            page.removeAnnotation(flash)
        }
    }

    private func clearFlash() {
        if let page = selectionFlashPage, let ann = selectionFlashAnnotation {
            page.removeAnnotation(ann)
        }
        selectionFlashAnnotation = nil
        selectionFlashPage = nil
    }

    private func shortPreview(_ s: String) -> String {
        let t = s.replacingOccurrences(of: "\n", with: " ")
        if t.count <= 40 { return t }
        return String(t.prefix(37)) + "…"
    }

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
