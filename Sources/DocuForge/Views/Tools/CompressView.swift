import SwiftUI
import UniformTypeIdentifiers
import DocuForgeCore

struct CompressView: View {
    @EnvironmentObject private var app: AppModel
    @State private var items: [DocumentItem] = []
    @State private var quality: CompressQuality = .medium
    @State private var job: JobState = .idle

    var body: some View {
        ToolChrome(
            title: "Compress",
            subtitle: "Reduce PDF size by re-encoding pages. Best for scan-heavy documents.",
            systemImage: "archivebox"
        ) {
            HStack {
                PrimaryActionButton(
                    title: "Compress",
                    systemImage: "archivebox",
                    enabled: !items.isEmpty && !job.isRunning
                ) {
                    Task { await run() }
                }
                Spacer()
            }
            JobStatusBanner(state: job, onReveal: app.revealInFinder, onOpen: app.open)
        } content: {
            if items.isEmpty {
                DropZoneView(
                    title: "Drop PDFs to compress",
                    subtitle: "Works entirely offline with PDFKit",
                    systemImage: "archivebox.fill",
                    allowedTypes: [.pdf],
                    allowsMultiple: true
                ) { urls in
                    items = urls.map { DocumentItem(url: $0) }
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    FileQueueView(items: $items)
                        .frame(minHeight: 160)
                    Picker("Quality", selection: $quality) {
                        ForEach(CompressQuality.allCases) { q in
                            Text(q.title).tag(q)
                        }
                    }
                    .pickerStyle(.segmented)
                    HStack {
                        Button("Add…") {
                            items.append(contentsOf: app.pickFiles(contentTypes: [.pdf]).map { DocumentItem(url: $0) })
                        }
                        Button("Clear", role: .destructive) { items = []; job = .idle }
                    }
                }
            }
        }
    }

    private func run() async {
        job = .running(progress: 0.05, message: "Compressing…")
        do {
            let dir = try app.makeOutputDirectory(named: "Compress")
            var outputs: [URL] = []
            let total = max(items.count, 1)
            for (idx, item) in items.enumerated() {
                job = .running(progress: Double(idx) / Double(total), message: item.displayName)
                let out = dir.appendingPathComponent(item.url.deletingPathExtension().lastPathComponent + "-compressed.pdf")
                let result = try await app.pdf.compress(url: item.url, quality: quality, outputURL: out)
                outputs.append(contentsOf: result.outputURLs)
            }
            app.recordOutputs(outputs)
            job = .succeeded(outputURLs: outputs)
        } catch {
            job = .failed(message: error.localizedDescription)
        }
    }
}
