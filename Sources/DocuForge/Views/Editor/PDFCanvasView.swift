import SwiftUI
import PDFKit
import AppKit

/// PDF canvas with Pages/Canva interaction:
/// - Drag to select
/// - Double-click / Edit tool click → inline text field ON the word
/// - Highlight tool: drag select then auto-apply on mouse up
struct PDFCanvasView: NSViewRepresentable {
    @ObservedObject var session: LivePDFSession

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeNSView(context: Context) -> InteractivePDFView {
        let view = InteractivePDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = NSColor.windowBackgroundColor
        view.document = session.document
        view.delegate = context.coordinator
        view.minScaleFactor = 0.25
        view.maxScaleFactor = 4.0
        context.coordinator.pdfView = view
        context.coordinator.apply(session: session, to: view)
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.pageChanged(_:)),
            name: .PDFViewPageChanged,
            object: view
        )
        return view
    }

    func updateNSView(_ pdfView: InteractivePDFView, context: Context) {
        context.coordinator.session = session
        if pdfView.document !== session.document {
            pdfView.document = session.document
        }
        context.coordinator.apply(session: session, to: pdfView)

        if context.coordinator.lastPageIndex != session.currentPageIndex {
            context.coordinator.lastPageIndex = session.currentPageIndex
            if let page = session.document.page(at: session.currentPageIndex) {
                pdfView.go(to: page)
            }
        }

        // Sync inline editor
        if session.inlineEditActive, let hit = session.selectedHit,
           let page = session.document.page(at: hit.pageIndex) {
            pdfView.showInlineEditor(
                text: session.inlineEditText,
                page: page,
                bounds: hit.bounds,
                fontSize: hit.fontSize,
                bold: hit.isBold,
                token: session.selectionFlashToken
            )
        } else {
            pdfView.hideInlineEditor()
        }

        if context.coordinator.lastCanvasRevision != session.canvasRevision {
            context.coordinator.lastCanvasRevision = session.canvasRevision
            pdfView.needsDisplay = true
        }
    }

    static func dismantleNSView(_ nsView: InteractivePDFView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
        nsView.hideInlineEditor()
    }

    @MainActor
    final class Coordinator: NSObject, PDFViewDelegate {
        var session: LivePDFSession
        weak var pdfView: InteractivePDFView?
        var lastPageIndex = -1
        var lastCanvasRevision = -1

        init(session: LivePDFSession) { self.session = session }

        func apply(session: LivePDFSession, to view: InteractivePDFView) {
            view.interactionMode = {
                switch session.tool {
                case .edit: return .edit
                case .highlight, .underline, .strike: return .markup
                case .select: return .select
                case .addText, .signature: return .stamp
                }
            }()

            view.onSingleClick = { [weak self] page, point in
                Task { @MainActor in self?.session.handleSingleClick(page: page, point: point) }
            }
            view.onDoubleClick = { [weak self] page, point in
                Task { @MainActor in self?.session.handleDoubleClick(page: page, point: point) }
            }
            view.onDragSelectionFinished = { [weak self] selection in
                Task { @MainActor in
                    guard let self else { return }
                    if self.session.tool.markupSubtype != nil {
                        self.session.applyMarkupFromPDFSelection(selection)
                    }
                }
            }
            view.onInlineCommit = { [weak self] text in
                Task { @MainActor in
                    guard let self else { return }
                    self.session.inlineEditText = text
                    self.session.commitInlineEdit()
                }
            }
            view.onInlineCancel = { [weak self] in
                Task { @MainActor in self?.session.endInlineEdit(commit: false) }
            }
            view.onInlineTextChange = { [weak self] text in
                Task { @MainActor in self?.session.inlineEditText = text }
            }
        }

        @objc func pageChanged(_ notification: Notification) {
            DispatchQueue.main.async { [weak self] in
                guard let self, let pdfView = self.pdfView,
                      let page = pdfView.currentPage, let doc = pdfView.document else { return }
                let idx = doc.index(for: page)
                if idx != NSNotFound, self.session.currentPageIndex != idx {
                    self.session.currentPageIndex = idx
                    self.session.refreshPageLines()
                    self.lastPageIndex = idx
                }
            }
        }
    }
}

enum PDFInteractionMode {
    case select, edit, markup, stamp
}

/// PDFView with inline editor overlay (NSTextField on the word).
final class InteractivePDFView: PDFView, NSTextFieldDelegate {
    nonisolated(unsafe) var interactionMode: PDFInteractionMode = .edit
    nonisolated(unsafe) var onSingleClick: ((PDFPage, CGPoint) -> Void)?
    nonisolated(unsafe) var onDoubleClick: ((PDFPage, CGPoint) -> Void)?
    nonisolated(unsafe) var onDragSelectionFinished: ((PDFSelection?) -> Void)?
    nonisolated(unsafe) var onInlineCommit: ((String) -> Void)?
    nonisolated(unsafe) var onInlineCancel: (() -> Void)?
    nonisolated(unsafe) var onInlineTextChange: ((String) -> Void)?

    private var inlineField: NSTextField?
    private var inlineToken: Int = -1
    private var didDrag = false

    override var acceptsFirstResponder: Bool { true }

    // MARK: - Inline editor

    func showInlineEditor(text: String, page: PDFPage, bounds: CGRect, fontSize: CGFloat, bold: Bool, token: Int) {
        var viewRect = convert(bounds, from: page)
        // Ensure readable field size
        viewRect = viewRect.insetBy(dx: -4, dy: -3)
        if viewRect.height < 22 { viewRect.size.height = 22 }
        if viewRect.width < 60 { viewRect.size.width = 60 }

        if let field = inlineField, inlineToken == token {
            if field.currentEditor() == nil, field.stringValue != text {
                field.stringValue = text
            }
            field.frame = viewRect
            return
        }

        hideInlineEditor()
        inlineToken = token

        let field = NSTextField(string: text)
        field.isBordered = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.isEditable = true
        field.isSelectable = true
        field.font = bold
            ? NSFont.boldSystemFont(ofSize: max(11, min(36, fontSize * scaleFactor * 0.9)))
            : NSFont.systemFont(ofSize: max(11, min(36, fontSize * scaleFactor * 0.9)))
        field.backgroundColor = NSColor.textBackgroundColor
        field.delegate = self
        field.target = self
        field.action = #selector(inlineSubmitted(_:))
        field.frame = viewRect
        addSubview(field)
        inlineField = field

        DispatchQueue.main.async {
            self.window?.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }
    }

    func hideInlineEditor() {
        inlineField?.removeFromSuperview()
        inlineField = nil
        inlineToken = -1
    }

    @objc private func inlineSubmitted(_ sender: NSTextField) {
        onInlineCommit?(sender.stringValue)
        hideInlineEditor()
    }

    func controlTextDidChange(_ obj: Notification) {
        if let field = obj.object as? NSTextField {
            onInlineTextChange?(field.stringValue)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if let field = control as? NSTextField {
                onInlineCommit?(field.stringValue)
                hideInlineEditor()
            }
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            onInlineCancel?()
            hideInlineEditor()
            return true
        }
        return false
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        didDrag = false
        let viewPoint = convert(event.locationInWindow, from: nil)

        // If clicking outside active inline field, commit first
        if let field = inlineField, !field.frame.contains(viewPoint) {
            onInlineCommit?(field.stringValue)
            hideInlineEditor()
        }

        if event.clickCount >= 2 {
            if let page = page(for: viewPoint, nearest: true) {
                let pagePoint = convert(viewPoint, to: page)
                onDoubleClick?(page, pagePoint)
            }
            return
        }

        switch interactionMode {
        case .select, .markup, .edit:
            // Allow native drag selection for highlight / multi-word edit
            super.mouseDown(with: event)
        case .stamp:
            if let page = page(for: viewPoint, nearest: true) {
                let pagePoint = convert(viewPoint, to: page)
                onSingleClick?(page, pagePoint)
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        didDrag = true
        if interactionMode == .stamp { return }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)

        switch interactionMode {
        case .markup:
            super.mouseUp(with: event)
            if didDrag {
                onDragSelectionFinished?(currentSelection)
            } else if let page = page(for: viewPoint, nearest: true) {
                // click word highlight
                let pagePoint = convert(viewPoint, to: page)
                onSingleClick?(page, pagePoint)
            }
        case .edit:
            super.mouseUp(with: event)
            if didDrag, let sel = currentSelection, let s = sel.string, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Drag-selected text → open inline edit for whole selection
                // Handled via session through double-path: notify as single click on mid?
                // Use commit selection for edit:
                if let page = sel.pages.first {
                    let bounds = sel.bounds(for: page)
                    let mid = CGPoint(x: bounds.midX, y: bounds.midY)
                    onDoubleClick?(page, mid)
                }
            } else if !didDrag, let page = page(for: viewPoint, nearest: true) {
                let pagePoint = convert(viewPoint, to: page)
                onSingleClick?(page, pagePoint)
            }
        case .select:
            super.mouseUp(with: event)
        case .stamp:
            break
        }
        didDrag = false
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        let cursor: NSCursor
        switch interactionMode {
        case .edit: cursor = .iBeam
        case .markup: cursor = .iBeam
        case .select: cursor = .arrow
        case .stamp: cursor = .crosshair
        }
        addCursorRect(bounds, cursor: cursor)
    }
}
