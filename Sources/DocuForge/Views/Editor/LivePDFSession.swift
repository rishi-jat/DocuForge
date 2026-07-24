import Foundation
import AppKit
import PDFKit
import DocuForgeCore

/// Live PDF session — Pages/Canva-style: select text, edit in place, highlight selection.
@MainActor
final class LivePDFSession: ObservableObject {
    /// Simplified tools — selection is always available for markup.
    enum Tool: String, CaseIterable, Identifiable {
        case edit      // double-click / click word → inline edit
        case highlight
        case underline
        case strike
        case addText
        case signature
        case select   // pure select/copy

        var id: String { rawValue }

        var title: String {
            switch self {
            case .edit: return "Edit text"
            case .highlight: return "Highlight"
            case .underline: return "Underline"
            case .strike: return "Strike"
            case .addText: return "Add text"
            case .signature: return "Sign"
            case .select: return "Select"
            }
        }

        var systemImage: String {
            switch self {
            case .edit: return "character.cursor.ibeam"
            case .highlight: return "highlighter"
            case .underline: return "underline"
            case .strike: return "strikethrough"
            case .addText: return "text.badge.plus"
            case .signature: return "signature"
            case .select: return "cursorarrow"
            }
        }

        var usesDragSelection: Bool {
            switch self {
            case .highlight, .underline, .strike, .select, .edit: return true
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
            case .highlight: return NSColor(calibratedRed: 1, green: 0.92, blue: 0.2, alpha: 1)
            case .underline: return .systemBlue
            case .strike: return .systemRed
            default: return nil
            }
        }
    }

    struct TextSelectionHit: Equatable {
        var pageIndex: Int
        var bounds: CGRect
        var originalText: String
        var fontSize: CGFloat
        var isBold: Bool
    }

    let document: PDFDocument
    private(set) var sourceURL: URL

    /// App build stamp so users can confirm they launched the new binary.
    static let buildLabel = "DocuForge Edit 2026.7.25"

    @Published var tool: Tool = .edit
    @Published var currentPageIndex: Int = 0
    @Published var isDirty: Bool = false
    @Published var status: String = ""
    @Published var findQuery: String = ""
    @Published var replaceQuery: String = ""
    @Published var caseSensitive: Bool = false
    @Published var matchCount: Int = 0
    @Published var findIndex: Int = 0
    @Published var textBoxDraft: String = ""
    @Published var pageImageForEdit: NSImage?
    @Published var showPageImageEditor: Bool = false
    @Published var showScreenshotTextEditor: Bool = false
    @Published var selectedHit: TextSelectionHit?
    @Published var selectionFlashToken: Int = 0
    @Published var canvasRevision: Int = 0
    @Published var pageLines: [PDFTextEditEngine.PageLine] = []
    /// Inline editor should open (canvas positions the field).
    @Published var inlineEditActive: Bool = false
    @Published var inlineEditText: String = ""

    private(set) var findHits: [PDFTextEditEngine.Match] = []

    init(document: PDFDocument, sourceURL: URL) {
        self.document = document
        self.sourceURL = sourceURL
        refreshPageLines()
        status = "\(Self.buildLabel). Double-click a word to edit (like Pages/Canva). Drag to highlight."
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
        findHits = PDFTextEditEngine.findMatches(in: document, query: findQuery, caseSensitive: caseSensitive)
        findIndex = 0
        matchCount = findHits.count
        if findQuery.isEmpty {
            status = "Type Find text, then Find."
        } else if matchCount == 0 {
            status = currentPageHasTextLayer
                ? "No matches for “\(findQuery)”."
                : "No matches. Scan/image page? Use Edit text in screenshot."
        } else {
            status = "\(matchCount) match(es). Replace All rewrites at matched size."
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
            status = "Nothing replaced for “\(q)”."
            matchCount = 0
            findHits = []
            bump()
            return
        }
        isDirty = true
        findHits = []
        matchCount = 0
        endInlineEdit(commit: false)
        refreshPageLines()
        status = "Replaced \(n) match(es) at matched size. Save when ready. [\(Self.buildLabel)]"
        bump()
    }

    func goToNextMatch() {
        guard !findHits.isEmpty else {
            refreshFind()
            return
        }
        findIndex = (findIndex + 1) % findHits.count
        let hit = findHits[findIndex]
        currentPageIndex = hit.pageIndex
        refreshPageLines()
        status = "Match \(findIndex + 1) of \(findHits.count)"
        bump()
    }

    // MARK: - Inline edit (Pages/Canva: double-click text → type → done)

    func beginInlineEdit(page: PDFPage, point: CGPoint) {
        let pageIndex = document.index(for: page)
        let idx = pageIndex == NSNotFound ? currentPageIndex : pageIndex
        if pageIndex != NSNotFound { currentPageIndex = pageIndex }

        guard PDFTextEditEngine.pageHasExtractableText(page) else {
            status = "No selectable text here. Use “Edit text in screenshot” for image pages."
            bump()
            return
        }

        guard let sel = PDFTextEditEngine.selectText(
            page: page,
            pageIndex: idx,
            point: point,
            preferLine: false
        ) else {
            status = "No word under cursor. Drag-select text, or use Page content list."
            bump()
            return
        }

        selectedHit = TextSelectionHit(
            pageIndex: sel.pageIndex,
            bounds: sel.bounds,
            originalText: sel.text,
            fontSize: sel.fontSize,
            isBold: sel.isBold
        )
        inlineEditText = sel.text
        inlineEditActive = true
        selectionFlashToken &+= 1
        status = "Editing “\(short(sel.text))” — type new text, press Return or Done."
        bump()
    }

    func beginInlineEditFromSelection(_ pdfSelection: PDFSelection) {
        guard let sel = PDFTextEditEngine.selectionFromPDFSelection(pdfSelection, document: document) else {
            status = "Could not read selection."
            bump()
            return
        }
        selectedHit = TextSelectionHit(
            pageIndex: sel.pageIndex,
            bounds: sel.bounds,
            originalText: sel.text,
            fontSize: sel.fontSize,
            isBold: sel.isBold
        )
        currentPageIndex = sel.pageIndex
        inlineEditText = sel.text
        inlineEditActive = true
        selectionFlashToken &+= 1
        status = "Editing selection “\(short(sel.text))”."
        bump()
    }

    func commitInlineEdit() {
        guard let hit = selectedHit else {
            endInlineEdit(commit: false)
            return
        }
        let newText = inlineEditText
        guard !newText.isEmpty else {
            status = "Text cannot be empty."
            bump()
            return
        }
        guard let page = document.page(at: hit.pageIndex) else {
            endInlineEdit(commit: false)
            return
        }
        let ok = PDFTextEditEngine.coverAndReplace(
            on: page,
            bounds: hit.bounds,
            newText: newText,
            originalText: hit.originalText
        )
        if ok {
            isDirty = true
            status = "Updated “\(short(hit.originalText))” → “\(short(newText))”."
            refreshPageLines()
        } else {
            status = "Could not apply edit."
        }
        endInlineEdit(commit: false)
        bump()
    }

    func endInlineEdit(commit: Bool) {
        if commit {
            commitInlineEdit()
            return
        }
        inlineEditActive = false
        inlineEditText = ""
        selectedHit = nil
        objectWillChange.send()
    }

    func applyPageLineEdit(line: PDFTextEditEngine.PageLine, newText: String) {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let page = document.page(at: line.pageIndex) else { return }
        if PDFTextEditEngine.coverAndReplace(
            on: page,
            bounds: line.bounds,
            newText: trimmed,
            originalText: line.text
        ) {
            isDirty = true
            refreshPageLines()
            status = "Updated line."
            bump()
        }
    }

    // MARK: - Markup on selection (Pages: select then highlight)

    func applyMarkupFromPDFSelection(_ selection: PDFSelection?) {
        guard let selection, let subtype = tool.markupSubtype, let color = tool.markupColor else { return }
        let text = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            status = "Drag over the words you want to \(tool.title.lowercased())."
            bump()
            return
        }
        let n = PDFTextEditEngine.applyMarkup(selection: selection, type: subtype, color: color)
        if n > 0 {
            isDirty = true
            status = "\(tool.title) applied to “\(short(text))”."
            bump()
        } else {
            status = "Could not \(tool.title.lowercased()) that selection."
            bump()
        }
    }

    /// Toolbar action: highlight whatever is currently selected in the PDF view.
    func applyMarkupToCurrentViewSelection(_ selection: PDFSelection?) {
        guard let selection else {
            status = "First drag-select text, then click Highlight."
            bump()
            return
        }
        let text = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            status = "First drag-select text, then click Highlight."
            bump()
            return
        }
        let n = PDFTextEditEngine.applyMarkup(
            selection: selection,
            type: .highlight,
            color: NSColor(calibratedRed: 1, green: 0.92, blue: 0.2, alpha: 1)
        )
        if n > 0 {
            isDirty = true
            status = "Highlighted “\(short(text))”."
            bump()
        }
    }

    // MARK: - Clicks

    func handleSingleClick(page: PDFPage, point: CGPoint) {
        let pageIndex = document.index(for: page)
        if pageIndex != NSNotFound { currentPageIndex = pageIndex }

        switch tool {
        case .edit:
            // Single click starts edit (Canva: click text object)
            beginInlineEdit(page: page, point: point)
        case .highlight, .underline, .strike:
            // Prefer drag; click still highlights one word
            guard let subtype = tool.markupSubtype, let color = tool.markupColor else { return }
            let idx = pageIndex == NSNotFound ? currentPageIndex : pageIndex
            let r = PDFTextEditEngine.applyMarkupAtPoint(
                page: page, pageIndex: idx, point: point, type: subtype, color: color
            )
            if r.count > 0 {
                isDirty = true
                status = "\(tool.title): “\(short(r.text ?? ""))”."
                bump()
            } else {
                status = "Drag across words to \(tool.title.lowercased())."
                bump()
            }
        case .addText:
            // Only Add text tool places a new box — never by accident
            let text = textBoxDraft.isEmpty ? "New text" : textBoxDraft
            let fontSize: CGFloat = 14
            let width = max(80, CGFloat(text.count) * fontSize * 0.55)
            let rect = CGRect(x: point.x, y: point.y - fontSize, width: width, height: fontSize * 1.4)
            if PDFTextEditEngine.coverAndReplace(on: page, bounds: rect, newText: text, originalText: text) {
                // coverAndReplace on empty area still paints white+text — good
                isDirty = true
                status = "Added “\(short(text))”. Switch to Edit text to change existing words."
                refreshPageLines()
                bump()
            }
        case .signature:
            let rect = CGRect(x: point.x - 80, y: point.y - 20, width: 160, height: 40)
            let ann = PDFAnnotation(bounds: rect, forType: .ink, withProperties: nil)
            ann.color = .black
            let path = NSBezierPath()
            path.move(to: CGPoint(x: 4, y: 20))
            path.curve(to: CGPoint(x: 156, y: 20), controlPoint1: CGPoint(x: 40, y: 36), controlPoint2: CGPoint(x: 120, y: 4))
            ann.add(path)
            page.addAnnotation(ann)
            isDirty = true
            status = "Signature added."
            bump()
        case .select:
            break
        }
    }

    func handleDoubleClick(page: PDFPage, point: CGPoint) {
        beginInlineEdit(page: page, point: point)
    }

    // MARK: - Screenshots / pages

    func beginEditPageAsImage() {
        guard let page = document.page(at: currentPageIndex) else { return }
        pageImageForEdit = render(page: page, dpi: 144)
        showPageImageEditor = true
        status = "Page image adjust."
        bump()
    }

    func beginScreenshotTextEdit() {
        guard let page = document.page(at: currentPageIndex) else { return }
        pageImageForEdit = render(page: page, dpi: 180)
        showScreenshotTextEditor = true
        status = "Screenshot OCR editor."
        bump()
    }

    func applyEditedPageImage(_ image: NSImage) {
        guard let newPage = PDFPage(image: image) else { return }
        if let old = document.page(at: currentPageIndex) { newPage.rotation = old.rotation }
        document.removePage(at: currentPageIndex)
        document.insert(newPage, at: currentPageIndex)
        isDirty = true
        showPageImageEditor = false
        showScreenshotTextEditor = false
        pageImageForEdit = nil
        refreshPageLines()
        status = "Page \(currentPageIndex + 1) updated."
        bump()
    }

    func pasteScreenshotReplacingPage() {
        guard let image = NSImage(pasteboard: .general) else {
            status = "Clipboard has no image."
            bump()
            return
        }
        applyEditedPageImage(image)
    }

    func insertBlankPage() {
        let size = document.page(at: currentPageIndex)?.bounds(for: .mediaBox).size
            ?? CGSize(width: 612, height: 792)
        let blank = PDFPage()
        blank.setBounds(CGRect(origin: .zero, size: size), for: .mediaBox)
        let at = min(currentPageIndex + 1, document.pageCount)
        document.insert(blank, at: at)
        currentPageIndex = at
        isDirty = true
        refreshPageLines()
        status = "Blank page inserted."
        bump()
    }

    func rotateCurrentPage(_ degrees: Int) {
        guard let page = document.page(at: currentPageIndex) else { return }
        page.rotation = (page.rotation + degrees) % 360
        if page.rotation < 0 { page.rotation += 360 }
        isDirty = true
        status = "Rotated."
        bump()
    }

    func deleteCurrentPage() {
        guard document.pageCount > 1 else {
            status = "Cannot delete the only page."
            bump()
            return
        }
        document.removePage(at: currentPageIndex)
        if currentPageIndex >= document.pageCount { currentPageIndex = document.pageCount - 1 }
        isDirty = true
        endInlineEdit(commit: false)
        refreshPageLines()
        status = "Page deleted."
        bump()
    }

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
        status = "Saved \(target.lastPathComponent)."
        bump()
        return target
    }

    private func short(_ s: String) -> String {
        let t = s.replacingOccurrences(of: "\n", with: " ")
        return t.count <= 36 ? t : String(t.prefix(33)) + "…"
    }

    private func bump() {
        canvasRevision &+= 1
        objectWillChange.send()
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
