import Foundation
import AppKit
import PDFKit
import DocuForgeCore

/// Live PDF document session for on-canvas editing.
@MainActor
final class LivePDFSession: ObservableObject {
    enum Tool: String, CaseIterable, Identifiable {
        case editText
        case addText
        case highlight
        case underline
        case strike
        case signature
        case stamp
        case screenshot
        case select

        var id: String { rawValue }

        var title: String {
            switch self {
            case .editText: return "Edit word"
            case .addText: return "Add text"
            case .highlight: return "Highlight"
            case .underline: return "Underline"
            case .strike: return "Strike"
            case .signature: return "Sign"
            case .stamp: return "Stamp"
            case .screenshot: return "Page shot"
            case .select: return "Select"
            }
        }

        var systemImage: String {
            switch self {
            case .editText: return "character.cursor.ibeam"
            case .addText: return "text.badge.plus"
            case .highlight: return "highlighter"
            case .underline: return "underline"
            case .strike: return "strikethrough"
            case .signature: return "signature"
            case .stamp: return "seal"
            case .screenshot: return "camera.viewfinder"
            case .select: return "cursorarrow"
            }
        }

        /// Tools that use native drag-selection (then annotate on mouse up).
        var usesDragSelection: Bool {
            switch self {
            case .select, .highlight, .underline, .strike: return true
            default: return false
            }
        }

        var markupSubtype: PDFAnnotationSubtype? {
            switch self {
            case .highlight: return .highlight
            case .underline: return .underline
            case .strike: return .strikeOut
            default: return nil
            }
        }

        var markupColor: NSColor? {
            switch self {
            case .highlight: return NSColor.systemYellow.withAlphaComponent(0.45)
            case .underline: return .systemBlue
            case .strike: return .systemRed
            default: return nil
            }
        }
    }

    enum TextPickMode: String, CaseIterable, Identifiable {
        case word, line
        var id: String { rawValue }
        var title: String { self == .word ? "Word" : "Line" }
    }

    struct TextSelectionHit: Equatable {
        var pageIndex: Int
        var bounds: CGRect
        var originalText: String
        var fontSize: CGFloat
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
    @Published var showScreenshotTextEditor: Bool = false
    @Published var textPickMode: TextPickMode = .word
    @Published var selectedHit: TextSelectionHit?
    /// Intentionally NOT driving heavy view refresh on every keystroke — UI holds local draft.
    var editDraft: String = ""
    @Published var selectionFlashToken: Int = 0
    @Published var canvasRevision: Int = 0
    @Published var lastClickDebug: String = ""
    @Published var pageLines: [PDFTextEditEngine.PageLine] = []
    @Published var showPageContentPanel: Bool = true

    private(set) var findHits: [PDFTextEditEngine.Match] = []

    private weak var selectionFlashAnnotation: PDFAnnotation?
    private weak var selectionFlashPage: PDFPage?

    init(document: PDFDocument, sourceURL: URL) {
        self.document = document
        self.sourceURL = sourceURL
        refreshPageLines()
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

    var currentPageHasTextLayer: Bool {
        guard let page = document.page(at: currentPageIndex) else { return false }
        return PDFTextEditEngine.pageHasExtractableText(page)
    }

    func goToPage(_ index: Int) {
        guard index >= 0, index < document.pageCount else { return }
        currentPageIndex = index
        refreshPageLines()
        bump()
    }

    func refreshPageLines() {
        guard let page = document.page(at: currentPageIndex) else {
            pageLines = []
            return
        }
        pageLines = PDFTextEditEngine.extractLines(page: page, pageIndex: currentPageIndex)
    }

    // MARK: - Find / replace

    func refreshFind() {
        findHits = PDFTextEditEngine.findMatches(
            in: document,
            query: findQuery,
            caseSensitive: caseSensitive
        )
        findIndex = 0
        matchCount = findHits.count
        if findQuery.isEmpty {
            status = "Type a word in Find, then press Find."
        } else if matchCount == 0 {
            if !currentPageHasTextLayer {
                status = "No matches. This page may be a scan — use “Edit text in screenshot”."
            } else {
                status = "No matches for “\(findQuery)”."
            }
        } else {
            status = "\(matchCount) match\(matchCount == 1 ? "" : "es"). Next jumps; Replace All rewrites at the same size."
            if let first = findHits.first {
                currentPageIndex = first.pageIndex
                refreshPageLines()
            }
        }
        bump()
    }

    func replaceAllPreservingLayout() {
        let q = findQuery
        guard !q.isEmpty else {
            status = "Enter Find text first."
            bump()
            return
        }
        let n = PDFTextEditEngine.replaceAll(
            in: document,
            query: q,
            replacement: replaceQuery,
            caseSensitive: caseSensitive
        )
        if n == 0 {
            status = currentPageHasTextLayer
                ? "Nothing to replace for “\(q)”."
                : "Nothing replaced — no selectable PDF text. Use “Edit text in screenshot”."
            matchCount = 0
            findHits = []
            bump()
            return
        }
        isDirty = true
        findHits = []
        matchCount = 0
        clearTextSelection()
        refreshPageLines()
        status = "Replaced \(n) occurrence(s) at matching size."
        bump()
    }

    func goToNextMatch() {
        guard !findHits.isEmpty else {
            refreshFind()
            guard !findHits.isEmpty else { return }
            return
        }
        findIndex = (findIndex + 1) % findHits.count
        let hit = findHits[findIndex]
        currentPageIndex = hit.pageIndex
        refreshPageLines()
        if let page = document.page(at: hit.pageIndex) {
            flashBounds(hit.bounds, on: page, color: NSColor.systemYellow.withAlphaComponent(0.45), seconds: 0.9)
        }
        status = "Match \(findIndex + 1) of \(findHits.count)"
        bump()
    }

    // MARK: - Click to edit

    func selectTextAt(page: PDFPage, pointInPage: CGPoint) {
        let pageIndex = document.index(for: page)
        let idx = pageIndex == NSNotFound ? currentPageIndex : pageIndex
        if pageIndex != NSNotFound {
            currentPageIndex = pageIndex
            refreshPageLines()
        }

        lastClickDebug = String(format: "click page=%d pt=(%.1f,%.1f)", idx + 1, pointInPage.x, pointInPage.y)

        if !PDFTextEditEngine.pageHasExtractableText(page) {
            clearTextSelection()
            status = "No text layer (scan/screenshot). Use “Edit text in screenshot” or the page content panel after OCR."
            bump()
            return
        }

        guard let sel = PDFTextEditEngine.selectText(
            page: page,
            pageIndex: idx,
            point: pointInPage,
            preferLine: textPickMode == .line
        ) else {
            clearTextSelection()
            status = "No word under click. Use the Page content list on the right to edit lines."
            bump()
            return
        }

        selectedHit = TextSelectionHit(
            pageIndex: sel.pageIndex,
            bounds: sel.bounds,
            originalText: sel.text,
            fontSize: sel.fontSize
        )
        editDraft = sel.text
        selectionFlashToken &+= 1
        if let p = document.page(at: sel.pageIndex) {
            flashSelection(on: p, bounds: sel.bounds)
        }
        status = "Selected “\(shortPreview(sel.text))”. Type in the blue bar (click the field), then Apply."
        bump()
    }

    func applySelectedTextEdit(draft: String? = nil) {
        guard let hit = selectedHit else {
            status = "Click a word, or edit a line in Page content."
            bump()
            return
        }
        let newText = (draft ?? editDraft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newText.isEmpty else {
            status = "Replacement text cannot be empty."
            bump()
            return
        }
        // Re-fetch page (burn replace swaps page objects)
        guard let page = document.page(at: hit.pageIndex) else {
            status = "Page no longer available."
            clearTextSelection()
            return
        }
        clearFlash()
        let ok = PDFTextEditEngine.coverAndReplace(
            on: page,
            bounds: hit.bounds,
            newText: newText,
            originalText: hit.originalText
        )
        guard ok else {
            status = "Could not apply edit."
            bump()
            return
        }
        isDirty = true
        let old = hit.originalText
        clearTextSelection()
        refreshPageLines()
        status = "Changed “\(shortPreview(old))” → “\(shortPreview(newText))” (matched size)."
        bump()
    }

    func applyPageLineEdit(line: PDFTextEditEngine.PageLine, newText: String) {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let page = document.page(at: line.pageIndex) else { return }
        clearFlash()
        let ok = PDFTextEditEngine.coverAndReplace(
            on: page,
            bounds: line.bounds,
            newText: trimmed,
            originalText: line.text
        )
        if ok {
            isDirty = true
            refreshPageLines()
            status = "Updated line: “\(shortPreview(trimmed))”."
            bump()
        } else {
            status = "Could not update that line."
            bump()
        }
    }

    func eraseSelectedText() {
        guard let hit = selectedHit,
              let page = document.page(at: hit.pageIndex) else {
            status = "Select text first."
            bump()
            return
        }
        clearFlash()
        // White cover via high-fidelity paint of blank
        _ = PDFTextEditEngine.coverAndReplace(
            on: page,
            bounds: hit.bounds,
            newText: " ",
            originalText: hit.originalText
        )
        isDirty = true
        clearTextSelection()
        refreshPageLines()
        status = "Erased selected text."
        bump()
    }

    func clearTextSelection() {
        clearFlash()
        selectedHit = nil
        editDraft = ""
        // Don't always bump — callers bump when needed
        objectWillChange.send()
    }

    // MARK: - Markup from drag selection (Pages/Canva style)

    func applyMarkupFromPDFSelection(_ selection: PDFSelection?) {
        guard let selection, let subtype = tool.markupSubtype, let color = tool.markupColor else {
            return
        }
        let text = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let n = PDFTextEditEngine.applyMarkup(selection: selection, type: subtype, color: color)
        if n > 0 {
            isDirty = true
            status = "\(tool.title): \(n) run(s)\(text.isEmpty ? "" : " on “\(shortPreview(text))”")."
            bump()
        } else {
            status = "Drag across text to \(tool.title.lowercased()), or click a word."
            bump()
        }
    }

    // MARK: - Canvas click tools

    func handleClick(page: PDFPage, pointInPage: CGPoint) {
        let pageIndex = document.index(for: page)
        if pageIndex != NSNotFound {
            currentPageIndex = pageIndex
        }

        switch tool {
        case .select:
            break
        case .editText:
            selectTextAt(page: page, pointInPage: pointInPage)
        case .addText:
            addFreeText(page: page, at: pointInPage, text: textBoxDraft.isEmpty ? "Text" : textBoxDraft)
        case .highlight, .underline, .strike:
            // Click = word markup; drag handled separately via selection
            guard let subtype = tool.markupSubtype, let color = tool.markupColor else { return }
            let idx = pageIndex == NSNotFound ? currentPageIndex : pageIndex
            let result = PDFTextEditEngine.applyMarkupAtPoint(
                page: page,
                pageIndex: idx,
                point: pointInPage,
                type: subtype,
                color: color,
                preferLine: false
            )
            if result.count > 0 {
                isDirty = true
                status = "\(tool.title) on “\(shortPreview(result.text ?? ""))”."
                bump()
            } else {
                status = "No word under click — drag across the text to \(tool.title.lowercased())."
                bump()
            }
        case .signature:
            let rect = CGRect(x: pointInPage.x - 80, y: pointInPage.y - 20, width: 160, height: 40)
            let ann = PDFAnnotation(bounds: rect, forType: .ink, withProperties: nil)
            ann.color = .black
            let path = NSBezierPath()
            path.move(to: CGPoint(x: 4, y: 20))
            path.curve(to: CGPoint(x: 156, y: 20), controlPoint1: CGPoint(x: 40, y: 36), controlPoint2: CGPoint(x: 120, y: 4))
            ann.add(path)
            page.addAnnotation(ann)
            isDirty = true
            status = "Added signature."
            bump()
        case .stamp:
            let text = stampDraft.isEmpty ? "APPROVED" : stampDraft
            let width = max(100, CGFloat(text.count) * 10)
            let rect = CGRect(x: pointInPage.x - width / 2, y: pointInPage.y - 16, width: width, height: 32)
            let box = PDFAnnotation(bounds: rect, forType: .freeText, withProperties: nil)
            box.contents = text
            box.font = NSFont.boldSystemFont(ofSize: 14)
            box.fontColor = .systemRed
            box.color = NSColor.white.withAlphaComponent(0.2)
            box.alignment = .center
            page.addAnnotation(box)
            isDirty = true
            status = "Stamped “\(text)”."
            bump()
        case .screenshot:
            beginEditPageAsImage()
        }
    }

    // MARK: - Screenshots

    func beginEditPageAsImage() {
        guard let page = document.page(at: currentPageIndex) else { return }
        pageImageForEdit = render(page: page, dpi: 144)
        showPageImageEditor = true
        status = "Page image adjust open."
        bump()
    }

    func beginScreenshotTextEdit() {
        guard let page = document.page(at: currentPageIndex) else { return }
        pageImageForEdit = render(page: page, dpi: 180)
        showScreenshotTextEditor = true
        status = "Screenshot text editor — detect & rewrite words in the page image."
        bump()
    }

    func applyEditedPageImage(_ image: NSImage) {
        guard let newPage = PDFPage(image: image) else {
            status = "Could not create page from image."
            bump()
            return
        }
        if let old = document.page(at: currentPageIndex) {
            newPage.rotation = old.rotation
        }
        document.removePage(at: currentPageIndex)
        document.insert(newPage, at: currentPageIndex)
        isDirty = true
        showPageImageEditor = false
        showScreenshotTextEditor = false
        pageImageForEdit = nil
        refreshPageLines()
        status = "Page \(currentPageIndex + 1) updated. Document remains PDF."
        bump()
    }

    func pasteScreenshotReplacingPage() {
        guard let image = NSImage(pasteboard: .general) ?? pasteboardImage() else {
            status = "Clipboard has no image. Capture with ⌘⇧4, copy, then paste."
            bump()
            return
        }
        applyEditedPageImage(image)
        status = "Replaced page \(currentPageIndex + 1) with clipboard screenshot."
        bump()
    }

    func pasteScreenshotAsNewPage() {
        guard let image = NSImage(pasteboard: .general) ?? pasteboardImage() else {
            status = "Clipboard has no image."
            bump()
            return
        }
        guard let newPage = PDFPage(image: image) else { return }
        let at = min(currentPageIndex + 1, document.pageCount)
        document.insert(newPage, at: at)
        currentPageIndex = at
        isDirty = true
        refreshPageLines()
        status = "Inserted screenshot as page \(at + 1)."
        bump()
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
        refreshPageLines()
        status = "Inserted blank page \(at + 1)."
        bump()
    }

    func rotateCurrentPage(_ degrees: Int) {
        guard let page = document.page(at: currentPageIndex) else { return }
        page.rotation = (page.rotation + degrees) % 360
        if page.rotation < 0 { page.rotation += 360 }
        isDirty = true
        status = "Rotated page \(currentPageIndex + 1)."
        bump()
    }

    func deleteCurrentPage() {
        guard document.pageCount > 1 else {
            status = "Cannot delete the only page."
            bump()
            return
        }
        document.removePage(at: currentPageIndex)
        if currentPageIndex >= document.pageCount {
            currentPageIndex = document.pageCount - 1
        }
        isDirty = true
        clearTextSelection()
        refreshPageLines()
        status = "Deleted page."
        bump()
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
        bump()
        return target
    }

    // MARK: - Helpers

    private func addFreeText(page: PDFPage, at point: CGPoint, text: String) {
        let size = CGSize(width: max(160, CGFloat(text.count) * 8), height: 28)
        let rect = CGRect(x: point.x, y: point.y - size.height / 2, width: size.width, height: size.height)
        let ann = PDFAnnotation(bounds: rect, forType: .freeText, withProperties: nil)
        ann.contents = text
        ann.font = NSFont.systemFont(ofSize: 14)
        ann.fontColor = .black
        ann.color = NSColor.white.withAlphaComponent(0.01)
        page.addAnnotation(ann)
        isDirty = true
        status = "Added text box “\(shortPreview(text))”."
        bump()
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

    private func bump() {
        canvasRevision &+= 1
        objectWillChange.send()
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
