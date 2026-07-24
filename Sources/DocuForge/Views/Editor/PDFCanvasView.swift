import SwiftUI
import PDFKit
import AppKit

/// Native PDFKit canvas — the PDF is shown and edited on-page.
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
        view.onPageClick = { [weak coordinator = context.coordinator] page, point in
            Task { @MainActor in
                coordinator?.session.handleClick(page: page, pointInPage: point)
            }
        }
        context.coordinator.pdfView = view
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.pageChanged(_:)),
            name: Notification.Name.PDFViewPageChanged,
            object: view
        )
        return view
    }

    func updateNSView(_ pdfView: ClickablePDFView, context: Context) {
        context.coordinator.session = session
        if pdfView.document !== session.document {
            pdfView.document = session.document
        }
        pdfView.activeToolIsSelect = { [session] in
            session.tool == .select
        }
        pdfView.onPageClick = { page, point in
            Task { @MainActor in
                session.handleClick(page: page, pointInPage: point)
            }
        }
        if let page = session.document.page(at: session.currentPageIndex),
           pdfView.currentPage != page {
            pdfView.go(to: page)
        }
    }

    static func dismantleNSView(_ nsView: ClickablePDFView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    final class Coordinator: NSObject, PDFViewDelegate {
        var session: LivePDFSession
        weak var pdfView: PDFView?

        init(session: LivePDFSession) {
            self.session = session
        }

        @objc func pageChanged(_ notification: Notification) {
            let pdfView = self.pdfView
            let session = self.session
            DispatchQueue.main.async {
                guard let pdfView,
                      let page = pdfView.currentPage,
                      let doc = pdfView.document else { return }
                let idx = doc.index(for: page)
                if idx != NSNotFound, session.currentPageIndex != idx {
                    session.currentPageIndex = idx
                }
            }
        }
    }
}

/// PDFView that maps clicks into page coordinates for tools.
final class ClickablePDFView: PDFView {
    var onPageClick: ((PDFPage, CGPoint) -> Void)?
    var activeToolIsSelect: (() -> Bool)?

    override func mouseDown(with event: NSEvent) {
        let isSelect = activeToolIsSelect?() ?? true
        if isSelect {
            super.mouseDown(with: event)
            return
        }
        let viewPoint = convert(event.locationInWindow, from: nil)
        if let page = page(for: viewPoint, nearest: true) {
            let pagePoint = convert(viewPoint, to: page)
            onPageClick?(page, pagePoint)
            return
        }
        super.mouseDown(with: event)
    }
}
