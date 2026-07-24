import SwiftUI
import UniformTypeIdentifiers
import DocuForgeCore

struct ConvertView: View {
    @EnvironmentObject private var app: AppModel
    @State private var items: [DocumentItem] = []
    @State private var target: DocumentFormat = .pdf
    @State private var job: JobState = .idle

    private let targets: [DocumentFormat] = [
        .pdf, .png, .jpeg, .heic, .tiff, .txt, .webp
    ]

    var body: some View {
        ToolChrome(
            title: "Convert",
            subtitle: "Transform documents and images offline. Office files export text content; iWork uses embedded previews when available.",
            systemImage: "arrow.triangle.2.circlepath"
        ) {
            HStack {
                PrimaryActionButton(
                    title: "Convert",
                    systemImage: "arrow.triangle.2.circlepath",
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
                    title: "Drop files to convert",
                    subtitle: "PDF, images, DOCX, PPTX, XLSX, RTF, HTML, TXT, and iWork packages",
                    systemImage: "square.and.arrow.down.on.square",
                    allowedTypes: [.item],
                    allowsMultiple: true
                ) { urls in
                    items = urls.map { DocumentItem(url: $0) }
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    FileQueueView(items: $items)
                        .frame(minHeight: 180)

                    HStack {
                        Button("Add More…") {
                            let urls = app.pickFiles(contentTypes: [.item])
                            items.append(contentsOf: urls.map { DocumentItem(url: $0) })
                        }
                        Button("Clear", role: .destructive) {
                            items = []
                            job = .idle
                        }
                        Spacer()
                        Picker("Convert to", selection: $target) {
                            ForEach(targets) { format in
                                Text(format.displayName).tag(format)
                            }
                        }
                        .frame(maxWidth: 260)
                    }
                }
            }
        }
    }

    private func run() async {
        job = .running(progress: 0.05, message: "Preparing…")
        do {
            let dir = try app.makeOutputDirectory(named: "Convert")
            var outputs: [URL] = []
            let total = max(items.count, 1)
            for (idx, item) in items.enumerated() {
                job = .running(progress: Double(idx) / Double(total), message: item.displayName)
                let result = try await app.conversion.convert(url: item.url, to: target, outputDirectory: dir)
                outputs.append(contentsOf: result.outputURLs)
            }
            app.recordOutputs(outputs)
            job = .succeeded(outputURLs: outputs)
        } catch {
            job = .failed(message: error.localizedDescription)
        }
    }
}
