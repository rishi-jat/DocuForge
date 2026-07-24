import SwiftUI
import UniformTypeIdentifiers
import DocuForgeCore

struct MergeView: View {
    @EnvironmentObject private var app: AppModel
    @State private var items: [DocumentItem] = []
    @State private var job: JobState = .idle

    var body: some View {
        ToolChrome(
            title: "Merge PDF",
            subtitle: "Combine multiple PDFs into one document. Use arrows to reorder.",
            systemImage: "doc.on.doc",
            content: {
                if items.isEmpty {
                    DropZoneView(
                        title: "Drop PDFs to merge",
                        subtitle: "Order in the list becomes the order in the final document",
                        systemImage: "doc.on.doc.fill",
                        allowedTypes: [.pdf],
                        allowsMultiple: true
                    ) { urls in
                        items = urls.filter { DocumentFormat.detect(url: $0) == .pdf }.map { DocumentItem(url: $0) }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Use ↑ ↓ to reorder")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        FileQueueView(items: $items, emptyMessage: "Add PDFs")
                            .frame(minHeight: 220)
                        HStack {
                            Button("Add PDFs…") {
                                let urls = app.pickFiles(contentTypes: [.pdf])
                                items.append(contentsOf: urls.map { DocumentItem(url: $0) })
                            }
                            Button("Clear", role: .destructive) {
                                items = []
                                job = .idle
                            }
                        }
                    }
                }
            },
            controls: {
                HStack {
                    PrimaryActionButton(
                        title: "Merge",
                        systemImage: "doc.on.doc",
                        enabled: items.count >= 2 && !job.isRunning
                    ) {
                        Task { await run() }
                    }
                    Spacer()
                }
                JobStatusBanner(state: job, onReveal: app.revealInFinder, onOpen: app.open)
            }
        )
    }

    private func run() async {
        job = .running(progress: 0.2, message: "Merging…")
        do {
            let dir = try app.makeOutputDirectory(named: "Merge")
            let out = dir.appendingPathComponent("merged.pdf")
            let result = try await app.pdf.merge(urls: items.map(\.url), outputURL: out)
            app.recordOutputs(result.outputURLs)
            job = .succeeded(outputURLs: result.outputURLs)
        } catch {
            job = .failed(message: error.localizedDescription)
        }
    }
}
