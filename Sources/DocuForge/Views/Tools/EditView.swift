import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine
import DocuForgeCore

/// Document editor — true WYSIWYG canvas (document scene model).
/// Primary path is NOT OCR / PDF glyph paint.
struct EditView: View {
    @EnvironmentObject private var app: AppModel

    @StateObject private var holder = EditorSessionHolder()
    @State private var statusMessage = ""
    @State private var errorMessage = ""
    @State private var isBusy = false

    var body: some View {
        VStack(spacing: 0) {
            if holder.session == nil {
                topBarEmpty
                if !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(8)
                }
                emptyState
            } else if let session = holder.session {
                DocumentEditorWorkspace(
                    session: session,
                    statusMessage: $statusMessage,
                    onSave: { Task { await save() } },
                    onSaveAs: { Task { await saveAs() } },
                    onClose: { close() }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var topBarEmpty: some View {
        HStack {
            Label("Document Editor", systemImage: "doc.richtext")
                .font(.headline)
            Spacer()
            Button("New blank") {
                holder.attach(DocumentEditorSession.blank())
                statusMessage = DocumentEditorSession.buildLabel
            }
            Button("Open…") {
                let urls = app.pickFiles(contentTypes: [.item], allowsMultiple: false)
                if let url = urls.first { Task { await open(url) } }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            DropZoneView(
                title: "Open a document to edit on the canvas",
                subtitle: "PDF, Word, text, and images open as a real document model — click objects, double-click text, drag to move. Not an OCR side-panel editor.",
                systemImage: "doc.badge.plus",
                allowedTypes: [.item],
                allowsMultiple: false
            ) { urls in
                if let url = urls.first { Task { await open(url) } }
            }
            .frame(maxWidth: 640)

            HStack(spacing: 16) {
                featureTip("Canvas-first", "Select, move, resize, and edit text in place — like Pages.")
                featureTip("Document model", "Edits change objects, then export clean PDF. No glyph cover-up.")
                featureTip("AI assistant", "Natural language plans with preview + undo.")
            }
            .frame(maxWidth: 900)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func featureTip(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(body).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func open(_ url: URL) async {
        errorMessage = ""
        statusMessage = ""
        isBusy = true
        defer { isBusy = false }
        do {
            let session = try DocumentEditorSession.open(url: url)
            holder.attach(session)
            statusMessage = "Opened \(url.lastPathComponent) as canvas document. \(DocumentEditorSession.buildLabel)"
            app.recordOutputs([]) // keep recent quiet
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func close() {
        holder.attach(nil)
        statusMessage = ""
        errorMessage = ""
    }

    private func save() async {
        guard let session = holder.session else { return }
        do {
            if session.sourceURL == nil {
                await saveAs()
                return
            }
            let url = try session.save()
            app.recordOutputs([url])
            statusMessage = session.status
        } catch {
            // No source — save as
            await saveAs()
        }
    }

    private func saveAs() async {
        guard let session = holder.session else { return }
        let name = (session.sourceURL?.deletingPathExtension().lastPathComponent ?? session.scene.title) + ".pdf"
        guard let dest = app.pickSaveURL(name: name, contentType: .pdf) else { return }
        do {
            let url = try session.save(to: dest)
            app.recordOutputs([url])
            statusMessage = session.status
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

@MainActor
final class EditorSessionHolder: ObservableObject {
    @Published var session: DocumentEditorSession?
    private var bag: AnyCancellable?

    func attach(_ s: DocumentEditorSession?) {
        session = s
        // Nested observable: rebroadcast
        if let s {
            bag = s.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        } else {
            bag = nil
        }
    }
}

