import SwiftUI
import PDFKit
import AppKit

/// Native PDFKit canvas with tool-aware click / drag.
struct PDFCanvasView: NSViewRepresentable {
    @ObservedObject var session: LivePDFSession

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    func makeNSView(context: Context) -> ClickablePDFView {
        let view = ClickablePDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = NSColor.windowBackgroundColor
        view.document = session.document
        view.delegate = context.coordinator
        view.minScaleFactor = 0.25
        view.maxScaleFactor = 4.0
        // Do NOT steal first responder — that blocks typing in the edit bar.
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

    func updateNSView(_ pdfView: ClickablePDFView, context: Context) {
        context.coordinator.session = session
        if pdfView.document !== session.document {
            pdfView.document = session.document
        }
        context.coordinator.apply(session: session, to: pdfView)

        // Only navigate when page index changes — avoid stealing focus every keystroke
        if context.coordinator.lastPageIndex != session.currentPageIndex {
            context.coordinator.lastPageIndex = session.currentPageIndex
            if let page = session.document.page(at: session.currentPageIndex) {
                pdfView.go(to: page)
            }
        }

        if context.coordinator.lastCanvasRevision != session.canvasRevision {
            context.coordinator.lastCanvasRevision = session.canvasRevision
            pdfView.needsDisplay = true
        }
    }

    static func dismantleNSView(_ nsView: ClickablePDFView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    @MainActor
    final class Coordinator: NSObject, PDFViewDelegate {
        var session: LivePDFSession
        weak var pdfView: ClickablePDFView?
        var lastPageIndex: Int = -1
        var lastCanvasRevision: Int = -1

        init(session: LivePDFSession) {
            self.session = session
        }

        func apply(session: LivePDFSession, to view: ClickablePDFView) {
            let tool = session.tool
            view.dragSelectMode = tool.usesDragSelection
            view.isMarkupTool = (tool.markupSubtype != nil)
            view.onPageClick = { [weak self] page, point in
                Task { @MainActor in
                    self?.session.handleClick(page: page, pointInPage: point)
                }
            }
            view.onDragSelectionFinished = { [weak self] selection in
                Task { @MainActor in
                    guard let self else { return }
                    if self.session.tool.markupSubtype != nil {
                        self.session.applyMarkupFromPDFSelection(selection)
                    }
                }
            }
        }

        @objc func pageChanged(_ notification: Notification) {
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      let pdfView = self.pdfView,
                      let page = pdfView.currentPage,
                      let doc = pdfView.document else { return }
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

/// PDFView: click tools vs drag-select markup tools.
final class ClickablePDFView: PDFView {
    nonisolated(unsafe) var dragSelectMode: Bool = false
    nonisolated(unsafe) var isMarkupTool: Bool = false
    nonisolated(unsafe) var onPageClick: ((PDFPage, CGPoint) -> Void)?
    nonisolated(unsafe) var onDragSelectionFinished: ((PDFSelection?) -> Void)?

    private var mouseDownPoint: NSPoint?
    private var didDrag = false

    override var acceptsFirstResponder: Bool { true }

    // Never force first responder — TextField must keep focus for typing.

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        didDrag = false

        if dragSelectMode {
            // Native text selection drag (Select / Highlight / Underline / Strike)
            super.mouseDown(with: event)
            return
        }

        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let page = page(for: viewPoint, nearest: true) else {
            super.mouseDown(with: event)
            return
        }
        let pagePoint = convert(viewPoint, to: page)
        onPageClick?(page, pagePoint)
    }

    override func mouseDragged(with event: NSEvent) {
        if dragSelectMode {
            didDrag = true
            super.mouseDragged(with: event)
            return
        }
        // click tools ignore drag
    }

    override func mouseUp(with event: NSEvent) {
        if dragSelectMode {
            super.mouseUp(with: event)
            if isMarkupTool {
                // Apply highlight/underline/strike to the dragged selection
                onDragSelectionFinished?(currentSelection)
            }
            mouseDownPoint = nil
            didDrag = false
            return
        }
        mouseDownPoint = nil
        didDrag = false
    }

    override func cursorUpdate(with event: NSEvent) {
        if dragSelectMode {
            NSCursor.iBeam.set()
        } else {
            NSCursor.crosshair.set()
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: dragSelectMode ? .iBeam : .crosshair)
    }
}
