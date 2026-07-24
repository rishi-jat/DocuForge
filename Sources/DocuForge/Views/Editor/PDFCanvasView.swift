import SwiftUI
import PDFKit
import AppKit

/// Native PDFKit canvas. Clicks are mapped to page coordinates for tools.
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

        if let page = session.document.page(at: session.currentPageIndex),
           pdfView.currentPage != page {
            pdfView.go(to: page)
        }

        _ = session.canvasRevision
        _ = session.selectionFlashToken
        pdfView.needsDisplay = true
    }

    static func dismantleNSView(_ nsView: ClickablePDFView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    @MainActor
    final class Coordinator: NSObject, PDFViewDelegate {
        var session: LivePDFSession
        weak var pdfView: ClickablePDFView?

        init(session: LivePDFSession) {
            self.session = session
        }

        func apply(session: LivePDFSession, to view: ClickablePDFView) {
            // Copy tool into a nonisolated flag so mouseDown (AppKit) can read it safely.
            view.selectModeEnabled = (session.tool == .select)
            view.onPageClick = { [weak self] page, point in
                // mouseDown is on the main thread; hop explicitly for Swift 6 isolation.
                Task { @MainActor in
                    self?.session.handleClick(page: page, pointInPage: point)
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
                }
            }
        }
    }
}

/// PDFView that always receives clicks for non-select tools.
final class ClickablePDFView: PDFView {
    /// Set from MainActor update cycle.
    nonisolated(unsafe) var selectModeEnabled: Bool = false
    nonisolated(unsafe) var onPageClick: ((PDFPage, CGPoint) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if selectModeEnabled {
            return super.hitTest(point)
        }
        return bounds.contains(point) ? self : super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        if selectModeEnabled {
            super.mouseDown(with: event)
            return
        }

        let windowPoint = event.locationInWindow
        let viewPoint = convert(windowPoint, from: nil)

        guard let page = page(for: viewPoint, nearest: true) else {
            super.mouseDown(with: event)
            return
        }
        let pagePoint = convert(viewPoint, to: page)
        onPageClick?(page, pagePoint)
    }

    override func cursorUpdate(with event: NSEvent) {
        if selectModeEnabled {
            NSCursor.arrow.set()
        } else {
            NSCursor.crosshair.set()
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: selectModeEnabled ? .arrow : .crosshair)
    }
}
