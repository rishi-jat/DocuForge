import SwiftUI
import UniformTypeIdentifiers
import DocuForgeCore

struct SplitView: View {
    @EnvironmentObject private var app: AppModel
    @State private var item: DocumentItem?
    @State private var mode: SplitMode = .everyPage
    @State private var rangesText: String = "1-1"
    @State private var everyN: Int = 2
    @State private var pageCount: Int = 0
    @State private var job: JobState = .idle

    var body: some View {
        ToolChrome(
            title: "Split PDF",
            subtitle: "Extract every page, fixed-size chunks, or custom ranges like 1-3, 5, 8-10.",
            systemImage: "scissors"
        ) {
            HStack {
                PrimaryActionButton(
                    title: "Split",
                    systemImage: "scissors",
                    enabled: item != nil && !job.isRunning
                ) {
                    Task { await run() }
                }
                Spacer()
            }
            JobStatusBanner(state: job, onReveal: app.revealInFinder, onOpen: app.open)
        } content: {
            if let item {
                VStack(alignment: .leading, spacing: 16) {
                    fileCard(item)
                    Picker("Mode", selection: $mode) {
                        ForEach(SplitMode.allCases) { m in
                            Text(m.title).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)

                    if mode == .ranges {
                        TextField("Ranges (e.g. 1-3, 5, 8-10)", text: $rangesText)
                            .textFieldStyle(.roundedBorder)
                    }
                    if mode == .everyN {
                        Stepper("Every \(everyN) pages", value: $everyN, in: 1...max(pageCount, 1))
                    }
                    Text("Document has \(pageCount) page\(pageCount == 1 ? "" : "s").")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Choose another PDF…") {
                        self.item = nil
                        job = .idle
                    }
                }
            } else {
                DropZoneView(
                    title: "Drop a PDF to split",
                    subtitle: "One document at a time",
                    systemImage: "scissors",
                    allowedTypes: [.pdf],
                    allowsMultiple: false
                ) { urls in
                    Task { await load(urls.first) }
                }
            }
        }
    }

    private func fileCard(_ item: DocumentItem) -> some View {
        HStack {
            Image(systemName: "doc.richtext")
            VStack(alignment: .leading) {
                Text(item.displayName).font(.headline)
                Text(item.formattedSize).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func load(_ url: URL?) async {
        guard let url, DocumentFormat.detect(url: url) == .pdf else { return }
        do {
            let count = try await app.pdf.pageCount(at: url)
            pageCount = count
            item = DocumentItem(url: url, pageCount: count)
            rangesText = count > 1 ? "1-\(count)" : "1"
        } catch {
            job = .failed(message: error.localizedDescription)
        }
    }

    private func run() async {
        guard let item else { return }
        job = .running(progress: 0.3, message: "Splitting…")
        do {
            let dir = try app.makeOutputDirectory(named: "Split")
            let result = try await app.pdf.split(
                url: item.url,
                mode: mode,
                rangesText: rangesText,
                everyN: everyN,
                outputDirectory: dir
            )
            app.recordOutputs(result.outputURLs)
            job = .succeeded(outputURLs: result.outputURLs)
        } catch {
            job = .failed(message: error.localizedDescription)
        }
    }
}
