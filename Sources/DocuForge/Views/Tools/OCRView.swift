import SwiftUI
import UniformTypeIdentifiers
import DocuForgeCore

struct OCRView: View {
    @EnvironmentObject private var app: AppModel
    @State private var item: DocumentItem?
    @State private var previewText: String = ""
    @State private var confidence: Float = 0
    @State private var job: JobState = .idle

    var body: some View {
        ToolChrome(
            title: "OCR",
            subtitle: "Recognize text on-device with Apple Vision. Export plain text or keep a PDF copy with a text sidecar.",
            systemImage: "text.viewfinder"
        ) {
            HStack(spacing: 12) {
                PrimaryActionButton(
                    title: "Run OCR",
                    systemImage: "text.viewfinder",
                    enabled: item != nil && !job.isRunning
                ) {
                    Task { await run(exportSearchable: false) }
                }
                Button {
                    Task { await run(exportSearchable: true) }
                } label: {
                    Label("PDF + Text", systemImage: "doc.text")
                }
                .controlSize(.large)
                .disabled(item == nil || item?.format != .pdf || job.isRunning)
                Spacer()
            }
            JobStatusBanner(state: job, onReveal: app.revealInFinder, onOpen: app.open)
        } content: {
            if let item {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: item.format.isImage ? "photo" : "doc.richtext")
                        Text(item.displayName).font(.headline)
                        Spacer()
                        if confidence > 0 {
                            Text("Confidence \(Int(confidence * 100))%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Button("Clear") {
                            self.item = nil
                            previewText = ""
                            confidence = 0
                            job = .idle
                        }
                    }
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))

                    TextEditor(text: $previewText)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 280)
                        .border(Color.primary.opacity(0.08))
                }
            } else {
                DropZoneView(
                    title: "Drop a PDF or image",
                    subtitle: "Scanned documents and photos work offline",
                    systemImage: "text.viewfinder",
                    allowedTypes: [.pdf, .image],
                    allowsMultiple: false
                ) { urls in
                    if let url = urls.first {
                        self.item = DocumentItem(url: url)
                        previewText = ""
                        confidence = 0
                    }
                }
            }
        }
    }

    private func run(exportSearchable: Bool) async {
        guard let item else { return }
        job = .running(progress: 0.2, message: "Recognizing text…")
        do {
            let dir = try app.makeOutputDirectory(named: "OCR")
            let base = item.url.deletingPathExtension().lastPathComponent

            if exportSearchable {
                let pdfOut = dir.appendingPathComponent("\(base)-copy.pdf")
                let txtOut = dir.appendingPathComponent("\(base)-ocr.txt")
                let result = try await app.ocr.makeSearchablePDF(sourcePDF: item.url, outputPDF: pdfOut, outputText: txtOut)
                previewText = (try? String(contentsOf: txtOut, encoding: .utf8)) ?? ""
                app.recordOutputs(result.outputURLs)
                job = .succeeded(outputURLs: result.outputURLs)
            } else {
                let ocrResult: OCRService.OCRResult
                if item.format == .pdf {
                    ocrResult = try await app.ocr.recognizePDF(url: item.url)
                } else {
                    ocrResult = try await app.ocr.recognizeText(in: item.url)
                }
                previewText = ocrResult.text
                confidence = ocrResult.confidence
                let txtOut = dir.appendingPathComponent("\(base)-ocr.txt")
                let result = try await app.ocr.exportText(ocrResult, to: txtOut)
                app.recordOutputs(result.outputURLs)
                job = .succeeded(outputURLs: result.outputURLs)
            }
        } catch {
            job = .failed(message: error.localizedDescription)
        }
    }
}
