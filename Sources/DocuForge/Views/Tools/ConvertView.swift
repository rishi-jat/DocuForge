import SwiftUI
import UniformTypeIdentifiers
import DocuForgeCore

struct ConvertView: View {
    @EnvironmentObject private var app: AppModel
    @State private var items: [DocumentItem] = []
    @State private var target: DocumentFormat = .pdf
    @State private var job: JobState = .idle
    @State private var envLines: [String] = []
    @State private var lastNotes: [String] = []

    private var targets: [DocumentFormat] {
        if let first = items.first {
            let suggested = first.format.suggestedTargets
            // Merge common targets while preferring suggested first
            var seen = Set<DocumentFormat>()
            var ordered: [DocumentFormat] = []
            for f in suggested + DocumentFormat.commonTargets where f != .unknown {
                if seen.insert(f).inserted { ordered.append(f) }
            }
            return ordered
        }
        return DocumentFormat.commonTargets
    }

    var body: some View {
        ToolChrome(
            title: "Convert",
            subtitle: "Broad format toolkit: documents, presentations, spreadsheets, images, EPUB, and archives. Uses PDFKit, ImageIO, textutil, iWork automation, Quick Look, and optional LibreOffice.",
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
            if !lastNotes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(lastNotes, id: \.self) { note in
                        Text("• \(note)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            JobStatusBanner(state: job, onReveal: app.revealInFinder, onOpen: app.open)
        } content: {
            if items.isEmpty {
                DropZoneView(
                    title: "Drop almost any document",
                    subtitle: "PDF · Office · iWork · ODF · RTF · Markdown · HTML · EPUB · images · ZIP/TAR",
                    systemImage: "square.and.arrow.down.on.square",
                    allowedTypes: [.item],
                    allowsMultiple: true
                ) { urls in
                    items = urls.map { DocumentItem(url: $0) }
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    FileQueueView(items: $items)
                        .frame(minHeight: 160)

                    HStack {
                        Button("Add More…") {
                            let urls = app.pickFiles(contentTypes: [.item])
                            items.append(contentsOf: urls.map { DocumentItem(url: $0) })
                        }
                        Button("Clear", role: .destructive) {
                            items = []
                            job = .idle
                            lastNotes = []
                        }
                        Spacer()
                        Picker("Convert to", selection: $target) {
                            ForEach(FormatCategory.allCases.filter { $0 != .other && $0 != .archive }) { cat in
                                let formats = targets.filter { $0.category == cat }
                                if !formats.isEmpty {
                                    Section(cat.title) {
                                        ForEach(formats) { format in
                                            Text(format.displayName).tag(format)
                                        }
                                    }
                                }
                            }
                            // Include remaining targets not in filtered categories
                            let rest = targets.filter { $0.category == .archive || $0.category == .other || $0.category == .ebook }
                            if !rest.isEmpty {
                                Section("Other") {
                                    ForEach(rest) { format in
                                        Text(format.displayName).tag(format)
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: 320)
                    }

                    formatHint
                }
            }

            if !envLines.isEmpty {
                DisclosureGroup("Conversion engines on this Mac") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(envLines, id: \.self) { line in
                            Text(line).font(.caption.monospaced())
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .task {
            envLines = await app.conversion.environmentSummary()
        }
        .onChange(of: items) { _, newItems in
            if let first = newItems.first {
                let suggested = first.format.suggestedTargets
                if !suggested.contains(target), let prefer = suggested.first {
                    target = prefer
                }
            }
        }
    }

    @ViewBuilder
    private var formatHint: some View {
        if let item = items.first {
            let fmt = item.format
            Group {
                if fmt.isIWork {
                    Label("iWork files use Pages/Keynote/Numbers automation when installed, then embedded preview, then Quick Look.", systemImage: "apple.logo")
                } else if fmt.isLegacyOffice && fmt != .doc {
                    Label("Legacy PPT/XLS need LibreOffice for full fidelity (not detected as a hard dependency).", systemImage: "exclamationmark.triangle")
                } else if fmt.isOfficeOpenXML {
                    Label("Office Open XML: textutil/LibreOffice for fidelity; built-in text extract as fallback.", systemImage: "doc.richtext")
                } else if fmt.isImage {
                    Label("Images convert via ImageIO (SVG rasterized when needed).", systemImage: "photo")
                } else if fmt == .epub {
                    Label("EPUB text is extracted offline and can be written to TXT/HTML/PDF.", systemImage: "book")
                } else if fmt.isArchive {
                    Label("Archives are extracted into a folder (ZIP can also be created from files).", systemImage: "archivebox")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func run() async {
        job = .running(progress: 0.05, message: "Preparing…")
        lastNotes = []
        do {
            let dir = try app.makeOutputDirectory(named: "Convert")
            var outputs: [URL] = []
            var notes: [String] = []
            let total = max(items.count, 1)
            for (idx, item) in items.enumerated() {
                job = .running(progress: Double(idx) / Double(total), message: "\(item.displayName) → \(target.displayName)")
                let result = try await app.conversion.convert(url: item.url, to: target, outputDirectory: dir)
                outputs.append(contentsOf: result.outputURLs)
                notes.append(contentsOf: result.notes)
            }
            lastNotes = Array(Set(notes))
            app.recordOutputs(outputs)
            job = .succeeded(outputURLs: outputs)
        } catch {
            job = .failed(message: error.localizedDescription)
        }
    }
}
