import SwiftUI
import UniformTypeIdentifiers
import PDFKit
import DocuForgeCore

struct PageManageView: View {
    @EnvironmentObject private var app: AppModel
    @State private var sourceURL: URL?
    @State private var pages: [PageThumb] = []
    @State private var selection = Set<UUID>()
    @State private var job: JobState = .idle

    struct PageThumb: Identifiable, Hashable {
        let id: UUID
        let sourceIndex: Int
        var rotation: Int
        var label: String
    }

    var body: some View {
        ToolChrome(
            title: "Pages",
            subtitle: "Reorder, rotate, delete, or extract pages. Changes are written to a new PDF.",
            systemImage: "rectangle.stack"
        ) {
            HStack(spacing: 10) {
                PrimaryActionButton(
                    title: "Save PDF",
                    systemImage: "square.and.arrow.down",
                    enabled: sourceURL != nil && !pages.isEmpty && !job.isRunning
                ) {
                    Task { await save() }
                }
                Button("Rotate Left") { rotateSelection(by: -90) }
                    .disabled(selection.isEmpty)
                Button("Rotate Right") { rotateSelection(by: 90) }
                    .disabled(selection.isEmpty)
                Button("Delete", role: .destructive) { deleteSelection() }
                    .disabled(selection.isEmpty)
                Spacer()
            }
            JobStatusBanner(state: job, onReveal: app.revealInFinder, onOpen: app.open)
        } content: {
            if sourceURL == nil {
                DropZoneView(
                    title: "Drop a PDF to manage pages",
                    subtitle: "Select pages, then rotate, delete, or reorder",
                    systemImage: "rectangle.stack",
                    allowedTypes: [.pdf],
                    allowsMultiple: false
                ) { urls in
                    Task { await load(urls.first) }
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(sourceURL!.lastPathComponent).font(.headline)
                        Spacer()
                        Text("\(pages.count) pages")
                            .foregroundStyle(.secondary)
                        Button("Close") {
                            sourceURL = nil
                            pages = []
                            selection = []
                            job = .idle
                        }
                    }
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 12)], spacing: 12) {
                            ForEach(pages) { page in
                                pageCell(page)
                            }
                        }
                    }
                    .frame(minHeight: 320)
                }
            }
        }
    }

    private func pageCell(_ page: PageThumb) -> some View {
        let selected = selection.contains(page.id)
        return VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .frame(height: 140)
                Text("\(page.sourceIndex + 1)")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.secondary)
                if page.rotation != 0 {
                    Text("\(page.rotation)°")
                        .font(.caption2)
                        .padding(4)
                        .background(.ultraThinMaterial, in: Capsule())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(6)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 2)
            )
            Text(page.label)
                .font(.caption)
        }
        .onTapGesture {
            if selection.contains(page.id) {
                selection.remove(page.id)
            } else {
                selection.insert(page.id)
            }
        }
        .contextMenu {
            Button("Move earlier") { move(page, by: -1) }
            Button("Move later") { move(page, by: 1) }
            Button("Rotate 90°") { rotate(pageID: page.id, by: 90) }
            Button("Delete", role: .destructive) {
                pages.removeAll { $0.id == page.id }
                selection.remove(page.id)
            }
        }
    }

    private func load(_ url: URL?) async {
        guard let url else { return }
        do {
            let count = try await app.pdf.pageCount(at: url)
            sourceURL = url
            pages = (0..<count).map {
                PageThumb(id: UUID(), sourceIndex: $0, rotation: 0, label: "Page \($0 + 1)")
            }
            selection = []
        } catch {
            job = .failed(message: error.localizedDescription)
        }
    }

    private func rotateSelection(by degrees: Int) {
        for id in selection {
            rotate(pageID: id, by: degrees)
        }
    }

    private func rotate(pageID: UUID, by degrees: Int) {
        guard let idx = pages.firstIndex(where: { $0.id == pageID }) else { return }
        pages[idx].rotation = (pages[idx].rotation + degrees) % 360
        if pages[idx].rotation < 0 { pages[idx].rotation += 360 }
    }

    private func deleteSelection() {
        pages.removeAll { selection.contains($0.id) }
        selection = []
    }

    private func move(_ page: PageThumb, by delta: Int) {
        guard let idx = pages.firstIndex(of: page) else { return }
        let newIndex = idx + delta
        guard pages.indices.contains(newIndex) else { return }
        pages.move(fromOffsets: IndexSet(integer: idx), toOffset: delta > 0 ? newIndex + 1 : newIndex)
    }

    private func save() async {
        guard let sourceURL else { return }
        job = .running(progress: 0.4, message: "Writing PDF…")
        do {
            let dir = try app.makeOutputDirectory(named: "Pages")
            let out = dir.appendingPathComponent(sourceURL.deletingPathExtension().lastPathComponent + "-edited.pdf")
            var rotations: [Int: Int] = [:]
            for p in pages where p.rotation != 0 {
                rotations[p.sourceIndex] = p.rotation
            }
            let result = try await app.pdf.reorderRotateDelete(
                url: sourceURL,
                orderedIndices: pages.map(\.sourceIndex),
                rotations: rotations,
                outputURL: out
            )
            app.recordOutputs(result.outputURLs)
            job = .succeeded(outputURLs: result.outputURLs)
        } catch {
            job = .failed(message: error.localizedDescription)
        }
    }
}
