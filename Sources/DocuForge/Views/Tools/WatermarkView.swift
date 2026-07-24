import SwiftUI
import UniformTypeIdentifiers
import DocuForgeCore

struct WatermarkView: View {
    @EnvironmentObject private var app: AppModel
    @State private var item: DocumentItem?
    @State private var options = WatermarkOptions()
    @State private var job: JobState = .idle

    var body: some View {
        ToolChrome(
            title: "Watermark",
            subtitle: "Stamp text across every page. Ideal for drafts, confidential marks, and branding.",
            systemImage: "drop.triangle"
        ) {
            HStack {
                PrimaryActionButton(
                    title: "Apply Watermark",
                    systemImage: "drop.triangle",
                    enabled: item != nil && !options.text.isEmpty && !job.isRunning
                ) {
                    Task { await run() }
                }
                Spacer()
            }
            JobStatusBanner(state: job, onReveal: app.revealInFinder, onOpen: app.open)
        } content: {
            if let item {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text(item.displayName).font(.headline)
                        Spacer()
                        Button("Clear") { self.item = nil; job = .idle }
                    }
                    TextField("Watermark text", text: $options.text)
                        .textFieldStyle(.roundedBorder)
                    Picker("Position", selection: $options.position) {
                        ForEach(WatermarkPosition.allCases) { p in
                            Text(p.title).tag(p)
                        }
                    }
                    HStack {
                        Text("Opacity")
                        Slider(value: $options.opacity, in: 0.05...0.8)
                        Text("\(Int(options.opacity * 100))%")
                            .monospacedDigit()
                            .frame(width: 40)
                    }
                    HStack {
                        Text("Size")
                        Slider(value: Binding(
                            get: { Double(options.fontSize) },
                            set: { options.fontSize = CGFloat($0) }
                        ), in: 18...120)
                        Text("\(Int(options.fontSize))")
                            .monospacedDigit()
                            .frame(width: 40)
                    }
                }
            } else {
                DropZoneView(
                    title: "Drop a PDF to watermark",
                    subtitle: "Text is drawn onto each page",
                    systemImage: "drop.triangle",
                    allowedTypes: [.pdf],
                    allowsMultiple: false
                ) { urls in
                    if let url = urls.first { item = DocumentItem(url: url) }
                }
            }
        }
    }

    private func run() async {
        guard let item else { return }
        job = .running(progress: 0.3, message: "Stamping pages…")
        do {
            let dir = try app.makeOutputDirectory(named: "Watermark")
            let out = dir.appendingPathComponent(item.url.deletingPathExtension().lastPathComponent + "-watermarked.pdf")
            let result = try await app.pdf.watermark(url: item.url, options: options, outputURL: out)
            app.recordOutputs(result.outputURLs)
            job = .succeeded(outputURLs: result.outputURLs)
        } catch {
            job = .failed(message: error.localizedDescription)
        }
    }
}
