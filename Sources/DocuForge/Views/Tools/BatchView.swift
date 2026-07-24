import SwiftUI
import UniformTypeIdentifiers
import DocuForgeCore

struct BatchView: View {
    @EnvironmentObject private var app: AppModel
    @State private var items: [DocumentItem] = []
    @State private var operation: BatchOperation = .compress
    @State private var quality: CompressQuality = .medium
    @State private var job: JobState = .idle
    @State private var reportSummary: String = ""

    var body: some View {
        ToolChrome(
            title: "Batch",
            subtitle: "Apply one operation to many files. Results land in Downloads/DocuForge.",
            systemImage: "square.stack.3d.up"
        ) {
            HStack {
                PrimaryActionButton(
                    title: "Run Batch",
                    systemImage: "play.fill",
                    enabled: !items.isEmpty && !job.isRunning
                ) {
                    Task { await run() }
                }
                Spacer()
            }
            if !reportSummary.isEmpty {
                Text(reportSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            JobStatusBanner(state: job, onReveal: app.revealInFinder, onOpen: app.open)
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                if items.isEmpty {
                    DropZoneView(
                        title: "Drop many files",
                        subtitle: "PDFs and images depending on the operation",
                        systemImage: "square.stack.3d.up.fill",
                        allowedTypes: [.item],
                        allowsMultiple: true
                    ) { urls in
                        items = urls.map { DocumentItem(url: $0) }
                    }
                } else {
                    FileQueueView(items: $items)
                        .frame(minHeight: 180)
                    HStack {
                        Button("Add…") {
                            items.append(contentsOf: app.pickFiles(contentTypes: [.item]).map { DocumentItem(url: $0) })
                        }
                        Button("Clear", role: .destructive) {
                            items = []
                            job = .idle
                            reportSummary = ""
                        }
                    }
                }

                Picker("Operation", selection: $operation) {
                    ForEach(BatchOperation.allCases.filter { $0 != .removePassword }) { op in
                        Text(op.title).tag(op)
                    }
                }
                if operation == .compress {
                    Picker("Quality", selection: $quality) {
                        ForEach(CompressQuality.allCases) { q in
                            Text(q.title).tag(q)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
        }
    }

    private func run() async {
        job = .running(progress: 0, message: "Starting…")
        reportSummary = ""
        let report = await app.batch.run(
            urls: items.map(\.url),
            operation: operation,
            quality: quality
        ) { progress, message in
            Task { @MainActor in
                job = .running(progress: progress, message: message)
            }
        }
        let outputs = report.results.flatMap(\.outputs)
        app.recordOutputs(outputs)
        reportSummary = "\(report.successCount) succeeded, \(report.failureCount) failed → \(report.outputDirectory.path)"
        if report.failureCount == 0, !outputs.isEmpty {
            job = .succeeded(outputURLs: outputs)
        } else if outputs.isEmpty {
            let err = report.results.compactMap(\.errorMessage).first ?? "Batch failed"
            job = .failed(message: err)
        } else {
            job = .succeeded(outputURLs: outputs + [report.outputDirectory])
        }
    }
}
