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

    /// Always expose full production target list (includes Pages / Keynote / Numbers).
    private var targets: [DocumentFormat] {
        var seen = Set<DocumentFormat>()
        var ordered: [DocumentFormat] = []
        let preferred: [DocumentFormat]
        if let first = items.first {
            preferred = first.format.suggestedTargets + DocumentFormat.commonTargets
        } else {
            preferred = DocumentFormat.commonTargets
        }
        for f in preferred where f != .unknown {
            if seen.insert(f).inserted { ordered.append(f) }
        }
        return ordered
    }

    var body: some View {
        ToolChrome(
            title: "Convert",
            subtitle: "Keep layout intact whenever possible. Pages, Keynote, and Numbers are used automatically when installed for high-fidelity Office ↔ PDF conversion.",
            systemImage: "arrow.triangle.2.circlepath"
        ) {
            HStack {
                PrimaryActionButton(
                    title: items.count > 1 ? "Convert \(items.count) Files" : "Convert",
                    systemImage: "arrow.triangle.2.circlepath",
                    enabled: !items.isEmpty && !job.isRunning
                ) {
                    Task { await run() }
                }
                if !items.isEmpty {
                    Text("→ \(target.displayName)")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            if !lastNotes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Conversion notes")
                        .font(.caption.weight(.semibold))
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
                    title: "Drop files to convert",
                    subtitle: "Pages · Keynote · Numbers · PDF · Word · PowerPoint · Excel · images · EPUB · ZIP",
                    systemImage: "square.and.arrow.down.on.square",
                    allowedTypes: [.item],
                    allowsMultiple: true
                ) { urls in
                    items = urls.map { DocumentItem(url: $0) }
                    if let first = items.first {
                        target = first.format.suggestedTargets.first ?? .pdf
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    fidelityBanner

                    FileQueueView(items: $items)
                        .frame(minHeight: 160)

                    HStack(alignment: .center) {
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
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Convert to")
                            .font(.headline)
                        Picker("Convert to", selection: $target) {
                            ForEach(targets) { format in
                                Text(formatLabel(format)).tag(format)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: 420, minHeight: 28)

                        // Quick chips for popular targets including iWork
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(quickTargets) { format in
                                    Button {
                                        target = format
                                    } label: {
                                        Text(format.displayName)
                                            .font(.caption.weight(.medium))
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 6)
                                            .background(
                                                Capsule().fill(target == format ? Color.accentColor.opacity(0.2) : Color(nsColor: .controlBackgroundColor))
                                            )
                                            .overlay(Capsule().strokeBorder(target == format ? Color.accentColor : Color.clear))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }

            if !envLines.isEmpty {
                DisclosureGroup("Engines on this Mac") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(envLines, id: \.self) { line in
                            Text(line).font(.caption.monospaced())
                        }
                        Text("Grant Automation access for Pages/Keynote/Numbers for layout-safe conversions.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
            }
        }
        .task { envLines = await app.conversion.environmentSummary() }
        .onChange(of: items) { _, newItems in
            if let first = newItems.first {
                let suggested = first.format.suggestedTargets
                if !suggested.contains(target), let prefer = suggested.first {
                    target = prefer
                }
            }
        }
    }

    private var quickTargets: [DocumentFormat] {
        [.pdf, .pages, .key, .numbers, .docx, .pptx, .xlsx, .png, .jpeg, .txt]
            .filter { targets.contains($0) }
    }

    private var fidelityBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Layout-safe conversion", systemImage: "checkmark.seal.fill")
                .font(.subheadline.weight(.semibold))
            Text(fidelityMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.08)))
    }

    private var fidelityMessage: String {
        guard let src = items.first?.format else {
            return "Drop a file to see the best conversion path."
        }
        if src.isIWork {
            return "\(src.displayName) → \(target.displayName): uses the matching Apple app when installed, then embedded preview / Quick Look as fallback."
        }
        if target == .pages || target == .key || target == .numbers {
            return "Exporting to \(target.displayName) uses \(target.displayName) automation when installed so layout stays faithful."
        }
        if [.pptx, .ppt, .docx, .doc].contains(src) && target == .pdf {
            return "Office → PDF prefers Keynote/Pages automation on this Mac so slides and documents don’t break like a naive import."
        }
        return "Source: \(src.displayName). Target: \(target.displayName)."
    }

    private func formatLabel(_ format: DocumentFormat) -> String {
        switch format {
        case .pages: return "Pages (.pages)"
        case .key: return "Keynote (.key)"
        case .numbers: return "Numbers (.numbers)"
        case .pptx: return "PowerPoint (.pptx)"
        case .docx: return "Word (.docx)"
        default: return format.displayName
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
