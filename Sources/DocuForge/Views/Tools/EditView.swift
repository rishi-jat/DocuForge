import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PDFKit
import DocuForgeCore

struct EditView: View {
    @EnvironmentObject private var app: AppModel

    enum Mode: String {
        case none, pdf, text, image
    }

    @State private var mode: Mode = .none
    @State private var sourceURL: URL?
    @State private var statusMessage: String = ""
    @State private var errorMessage: String = ""
    @State private var isBusy = false

    // PDF state
    @State private var pdfSessionID: UUID?
    @State private var pdfSnapshot: PDFEditorService.SessionSnapshot?
    @State private var selectedPage = 0
    @State private var pageOrder: [Int] = []
    @State private var annotationText = "Note"
    @State private var watermarkText = "CONFIDENTIAL"
    @State private var freeTextContent = "Text"
    @State private var signatureName = "Signature"
    @State private var cropInset: Double = 0.05
    @State private var previewImages: [Int: NSImage] = [:]

    // Text state
    @State private var textDocument: TextEditorService.TextDocument?
    @State private var textBody = ""
    @State private var textDirty = false

    // Image state
    @State private var imageOriginal: NSImage?
    @State private var imageWorking: NSImage?
    @State private var imageFormat: DocumentFormat = .png
    @State private var brightness: Double = 0
    @State private var contrast: Double = 1
    @State private var saturation: Double = 1
    @State private var resizeWidth: Double = 0
    @State private var resizeHeight: Double = 0
    @State private var cropEnabled = false
    @State private var imageDirty = false
    @State private var imageLimitation: String?

    var body: some View {
        ToolChrome(
            title: "Edit",
            subtitle: "Modify PDFs, text documents, and images in place. Save writes back to the original format when possible.",
            systemImage: "pencil.and.outline"
        ) {
            HStack(spacing: 10) {
                if mode != .none {
                    Button("Close") { closeSession() }
                    Button("Save") { Task { await save() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(isBusy || !canSave)
                    Button("Save As…") { Task { await saveAs() } }
                        .disabled(isBusy)
                }
                Spacer()
                if isBusy { ProgressView().controlSize(.small) }
            }
            if !statusMessage.isEmpty {
                Label(statusMessage, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            }
            if !errorMessage.isEmpty {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            }
        } content: {
            switch mode {
            case .none:
                openZone
            case .pdf:
                pdfEditor
            case .text:
                textEditor
            case .image:
                imageEditor
            }
        }
    }

    private var canSave: Bool {
        switch mode {
        case .pdf: return pdfSessionID != nil
        case .text: return textDirty && textDocument != nil
        case .image: return imageDirty && imageWorking != nil
        case .none: return false
        }
    }

    // MARK: - Open

    private var openZone: some View {
        DropZoneView(
            title: "Drop a file to edit",
            subtitle: "PDF · TXT/MD/RTF/DOC/DOCX · PNG/JPEG/HEIC/TIFF and more",
            systemImage: "pencil.and.outline",
            allowedTypes: [.item],
            allowsMultiple: false
        ) { urls in
            if let url = urls.first {
                Task { await open(url) }
            }
        }
    }

    // MARK: - PDF Editor

    private var pdfEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerBar(icon: "doc.richtext", title: pdfSnapshot?.fileName ?? "PDF", detail: "\(pdfSnapshot?.pageCount ?? 0) pages")

            HStack(alignment: .top, spacing: 16) {
                // Page list
                VStack(alignment: .leading, spacing: 8) {
                    Text("Pages").font(.headline)
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(Array(pageOrder.enumerated()), id: \.offset) { displayIndex, sourceIndex in
                                pageThumb(displayIndex: displayIndex, sourceIndex: sourceIndex)
                            }
                        }
                    }
                    .frame(width: 160, height: 360)
                }

                // Tools
                VStack(alignment: .leading, spacing: 12) {
                    GroupBox("Page") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Button("Rotate −90°") { Task { await rotate(-90) } }
                                Button("Rotate +90°") { Task { await rotate(90) } }
                                Button("Delete", role: .destructive) { Task { await deleteSelected() } }
                            }
                            HStack {
                                Button("Move Up") { Task { await moveSelected(delta: -1) } }
                                Button("Move Down") { Task { await moveSelected(delta: 1) } }
                            }
                            HStack {
                                Button("Insert Blank") { Task { await insertBlank() } }
                                Button("Insert Image…") { Task { await insertImage() } }
                            }
                            HStack {
                                Text("Crop inset")
                                Slider(value: $cropInset, in: 0.0...0.35)
                                Button("Apply Crop") { Task { await cropSelected() } }
                            }
                        }
                        .padding(4)
                    }

                    GroupBox("Annotate") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Button("Highlight") { Task { await addHighlight() } }
                                Button("Underline") { Task { await addUnderline() } }
                                Button("Strike") { Task { await addStrike() } }
                            }
                            HStack {
                                TextField("Text box", text: $freeTextContent)
                                Button("Add Text") { Task { await addFreeText() } }
                            }
                            HStack {
                                TextField("Signature label", text: $signatureName)
                                Button("Sign") { Task { await addSignature() } }
                            }
                            HStack {
                                TextField("Stamp / note", text: $annotationText)
                                Button("Stamp") { Task { await addStamp() } }
                            }
                            HStack {
                                TextField("Watermark", text: $watermarkText)
                                Button("Watermark all") { Task { await addWatermark() } }
                            }
                            Button("Clear page annotations", role: .destructive) {
                                Task { await clearAnnotations() }
                            }
                        }
                        .padding(4)
                    }

                    Text("Annotations and page structure save into the original PDF. Crop uses the PDF crop box (non-destructive to media).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func pageThumb(displayIndex: Int, sourceIndex: Int) -> some View {
        let selected = selectedPage == displayIndex
        return VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .frame(height: 120)
                if let img = previewImages[sourceIndex] {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 110)
                        .padding(4)
                } else {
                    Text("\(displayIndex + 1)")
                        .foregroundStyle(.secondary)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 2)
            )
            Text("Page \(displayIndex + 1)")
                .font(.caption2)
        }
        .onTapGesture { selectedPage = displayIndex }
        .onAppear { Task { await loadPreview(sourceIndex: sourceIndex) } }
    }

    // MARK: - Text Editor

    private var textEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerBar(
                icon: "doc.plaintext",
                title: textDocument?.sourceURL.lastPathComponent ?? "Text",
                detail: textDocument?.format.displayName ?? ""
            )
            if let note = textDocument?.limitationNote {
                Label(note, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextEditor(text: $textBody)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 420)
                .border(Color.primary.opacity(0.08))
                .onChange(of: textBody) { _, _ in textDirty = true }
        }
    }

    // MARK: - Image Editor

    private var imageEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerBar(
                icon: "photo",
                title: sourceURL?.lastPathComponent ?? "Image",
                detail: imageFormat.displayName
            )
            if let imageLimitation {
                Label(imageLimitation, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 16) {
                Group {
                    if let imageWorking {
                        Image(nsImage: imageWorking)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 480, maxHeight: 420)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    GroupBox("Adjustments") {
                        VStack(alignment: .leading, spacing: 8) {
                            labeledSlider("Brightness", value: $brightness, range: -0.5...0.5)
                            labeledSlider("Contrast", value: $contrast, range: 0.5...1.5)
                            labeledSlider("Saturation", value: $saturation, range: 0...2)
                        }
                        .padding(4)
                    }
                    GroupBox("Geometry") {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Crop 10% margins", isOn: $cropEnabled)
                            HStack {
                                TextField("Width", value: $resizeWidth, format: .number)
                                    .frame(width: 90)
                                Text("×")
                                TextField("Height", value: $resizeHeight, format: .number)
                                    .frame(width: 90)
                                Text("px").foregroundStyle(.secondary)
                            }
                            HStack {
                                Button("Apply") { Task { await applyImageEdits() } }
                                    .buttonStyle(.borderedProminent)
                                Button("Reset") { resetImage() }
                            }
                        }
                        .padding(4)
                    }
                    Text("Saves back to \(imageFormat.displayName) when the format supports writing. SVG/PSD export is limited.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func labeledSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title).frame(width: 90, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: "%.2f", value.wrappedValue))
                .monospacedDigit()
                .frame(width: 44)
        }
    }

    private func headerBar(icon: String, title: String, detail: String) -> some View {
        HStack {
            Image(systemName: icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let sourceURL {
                Button("Show in Finder") { app.revealInFinder(sourceURL) }
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }

    // MARK: - Open / Close / Save

    private func open(_ url: URL) async {
        errorMessage = ""
        statusMessage = ""
        let format = DocumentFormat.detect(url: url)
        isBusy = true
        defer { isBusy = false }
        do {
            if format == .pdf {
                let opened = try await app.pdfEditor.open(url: url)
                pdfSessionID = opened.id
                pdfSnapshot = opened.snapshot
                pageOrder = Array(0..<opened.snapshot.pageCount)
                selectedPage = 0
                previewImages = [:]
                sourceURL = url
                mode = .pdf
                statusMessage = "Opened PDF for editing."
            } else if format.isImage {
                let img = try await app.imageEditor.load(url: url)
                imageOriginal = img
                imageWorking = img
                imageFormat = format
                resizeWidth = Double(img.size.width)
                resizeHeight = Double(img.size.height)
                brightness = 0; contrast = 1; saturation = 1
                cropEnabled = false
                imageDirty = false
                sourceURL = url
                mode = .image
                if format == .svg || format == .psd {
                    imageLimitation = "\(format.displayName) has limited write support; save may use TIFF/PNG alternative if needed."
                } else {
                    imageLimitation = nil
                }
                statusMessage = "Opened image for editing."
            } else if await isTextEditable(format) {
                let doc = try await app.textEditor.open(url: url)
                textDocument = doc
                textBody = doc.text
                textDirty = false
                sourceURL = url
                mode = .text
                statusMessage = "Opened \(doc.format.displayName) for editing."
            } else {
                errorMessage = "No editor for \(format.displayName). Convert to PDF, TXT, or an image first."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func isTextEditable(_ format: DocumentFormat) async -> Bool {
        await app.textEditor.isEditableTextFormat(format)
    }

    private func closeSession() {
        if let id = pdfSessionID {
            Task { await app.pdfEditor.close(id: id) }
        }
        pdfSessionID = nil
        pdfSnapshot = nil
        pageOrder = []
        previewImages = [:]
        textDocument = nil
        textBody = ""
        textDirty = false
        imageOriginal = nil
        imageWorking = nil
        imageDirty = false
        sourceURL = nil
        mode = .none
        statusMessage = ""
        errorMessage = ""
    }

    private func save() async {
        errorMessage = ""
        isBusy = true
        defer { isBusy = false }
        do {
            switch mode {
            case .pdf:
                guard let id = pdfSessionID else { return }
                let result = try await app.pdfEditor.save(id: id)
                app.recordOutputs(result.outputURLs)
                statusMessage = "Saved \(result.outputURLs.first?.lastPathComponent ?? "PDF")."
                await refreshPDFSnapshot()
            case .text:
                guard var doc = textDocument else { return }
                doc.text = textBody
                let result = try await app.textEditor.save(doc)
                textDocument = doc
                textDirty = false
                app.recordOutputs(result.outputURLs)
                statusMessage = result.notes.joined(separator: " ")
            case .image:
                guard let image = imageWorking, let url = sourceURL else { return }
                let format = imageFormat
                if await app.imageEditor.canSaveNative(format: format) {
                    let result = try await app.imageEditor.save(image: image, to: url, format: format)
                    app.recordOutputs(result.outputURLs)
                    imageDirty = false
                    statusMessage = "Saved \(url.lastPathComponent)."
                } else {
                    // Fallback PNG beside original
                    let pngURL = url.deletingPathExtension().appendingPathExtension("png")
                    let result = try await app.imageEditor.save(image: image, to: pngURL, format: .png)
                    app.recordOutputs(result.outputURLs)
                    statusMessage = "\(format.displayName) cannot be written fully; saved PNG instead: \(pngURL.lastPathComponent)"
                    imageDirty = false
                }
            case .none:
                break
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveAs() async {
        errorMessage = ""
        guard let sourceURL else { return }
        let format = DocumentFormat.detect(url: sourceURL)
        guard let dest = app.pickSaveURL(name: sourceURL.lastPathComponent, contentType: format.utType) else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            switch mode {
            case .pdf:
                guard let id = pdfSessionID else { return }
                let result = try await app.pdfEditor.saveAs(id: id, url: dest)
                app.recordOutputs(result.outputURLs)
                self.sourceURL = dest
                statusMessage = "Saved as \(dest.lastPathComponent)."
            case .text:
                guard var doc = textDocument else { return }
                doc.text = textBody
                let result = try await app.textEditor.save(doc, to: dest)
                textDocument?.sourceURL = dest
                textDirty = false
                self.sourceURL = dest
                app.recordOutputs(result.outputURLs)
                statusMessage = "Saved as \(dest.lastPathComponent)."
            case .image:
                guard let image = imageWorking else { return }
                let result = try await app.imageEditor.save(image: image, to: dest, format: DocumentFormat.detect(url: dest))
                self.sourceURL = dest
                imageDirty = false
                app.recordOutputs(result.outputURLs)
                statusMessage = "Saved as \(dest.lastPathComponent)."
            case .none:
                break
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - PDF actions

    private func refreshPDFSnapshot() async {
        guard let id = pdfSessionID else { return }
        do {
            let snap = try await app.pdfEditor.snapshot(id: id)
            pdfSnapshot = snap
            // Keep order if same count else reset
            if pageOrder.count != snap.pageCount {
                pageOrder = Array(0..<snap.pageCount)
            }
            previewImages = [:]
            if selectedPage >= snap.pageCount { selectedPage = max(0, snap.pageCount - 1) }
            for i in pageOrder { await loadPreview(sourceIndex: i) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadPreview(sourceIndex: Int) async {
        guard let id = pdfSessionID, previewImages[sourceIndex] == nil else { return }
        do {
            let data = try await app.pdfEditor.pagePreview(id: id, pageIndex: sourceIndex)
            if let img = NSImage(data: data) {
                previewImages[sourceIndex] = img
            }
        } catch { /* ignore preview errors */ }
    }

    private func currentSourceIndex() -> Int? {
        guard selectedPage >= 0, selectedPage < pageOrder.count else { return nil }
        return pageOrder[selectedPage]
    }

    private func rotate(_ degrees: Int) async {
        guard let id = pdfSessionID, let src = currentSourceIndex() else { return }
        do {
            try await app.pdfEditor.rotatePage(id: id, pageIndex: src, degrees: degrees)
            previewImages[src] = nil
            await loadPreview(sourceIndex: src)
            statusMessage = "Rotated page \(selectedPage + 1)."
        } catch { errorMessage = error.localizedDescription }
    }

    private func deleteSelected() async {
        guard let id = pdfSessionID, let src = currentSourceIndex() else { return }
        do {
            try await app.pdfEditor.deletePages(id: id, indices: [src])
            await refreshPDFSnapshot()
            statusMessage = "Deleted page."
        } catch { errorMessage = error.localizedDescription }
    }

    private func moveSelected(delta: Int) async {
        guard let id = pdfSessionID else { return }
        let from = selectedPage
        let to = from + delta
        guard to >= 0, to < pageOrder.count else { return }
        var order = pageOrder
        order.swapAt(from, to)
        do {
            try await app.pdfEditor.reorderPages(id: id, orderedIndices: order)
            pageOrder = order
            selectedPage = to
            await refreshPDFSnapshot()
            statusMessage = "Moved page."
        } catch { errorMessage = error.localizedDescription }
    }

    private func insertBlank() async {
        guard let id = pdfSessionID else { return }
        let at = min(selectedPage + 1, pageOrder.count)
        do {
            try await app.pdfEditor.insertBlankPage(id: id, at: at)
            await refreshPDFSnapshot()
            selectedPage = at
            statusMessage = "Inserted blank page."
        } catch { errorMessage = error.localizedDescription }
    }

    private func insertImage() async {
        guard let id = pdfSessionID else { return }
        let urls = app.pickFiles(contentTypes: [.image], allowsMultiple: false)
        guard let url = urls.first else { return }
        let at = min(selectedPage + 1, pageOrder.count)
        do {
            try await app.pdfEditor.insertImagePage(id: id, imageURL: url, at: at)
            await refreshPDFSnapshot()
            selectedPage = at
            statusMessage = "Inserted image page."
        } catch { errorMessage = error.localizedDescription }
    }

    private func cropSelected() async {
        guard let id = pdfSessionID, let src = currentSourceIndex() else { return }
        let inset = cropInset
        let norm = CGRect(x: inset, y: inset, width: 1 - inset * 2, height: 1 - inset * 2)
        do {
            try await app.pdfEditor.cropPage(id: id, pageIndex: src, normalizedRect: norm)
            previewImages[src] = nil
            await loadPreview(sourceIndex: src)
            statusMessage = "Cropped page \(selectedPage + 1)."
        } catch { errorMessage = error.localizedDescription }
    }

    private func annotationRect() async throws -> (UUID, Int, CGRect) {
        guard let id = pdfSessionID, let src = currentSourceIndex() else {
            throw DocuForgeError.invalidInput("No page selected.")
        }
        let bounds = try await app.pdfEditor.pageBounds(id: id, pageIndex: src)
        // Center band for annotations
        let rect = CGRect(
            x: bounds.width * 0.15,
            y: bounds.height * 0.45,
            width: bounds.width * 0.7,
            height: bounds.height * 0.12
        )
        return (id, src, rect)
    }

    private func addHighlight() async {
        do {
            let (id, src, rect) = try await annotationRect()
            try await app.pdfEditor.addHighlight(id: id, pageIndex: src, rect: rect)
            previewImages[src] = nil
            await loadPreview(sourceIndex: src)
            statusMessage = "Added highlight."
        } catch { errorMessage = error.localizedDescription }
    }

    private func addUnderline() async {
        do {
            let (id, src, rect) = try await annotationRect()
            try await app.pdfEditor.addUnderline(id: id, pageIndex: src, rect: rect)
            previewImages[src] = nil
            await loadPreview(sourceIndex: src)
            statusMessage = "Added underline."
        } catch { errorMessage = error.localizedDescription }
    }

    private func addStrike() async {
        do {
            let (id, src, rect) = try await annotationRect()
            try await app.pdfEditor.addStrikethrough(id: id, pageIndex: src, rect: rect)
            previewImages[src] = nil
            await loadPreview(sourceIndex: src)
            statusMessage = "Added strikethrough."
        } catch { errorMessage = error.localizedDescription }
    }

    private func addFreeText() async {
        do {
            let (id, src, rect) = try await annotationRect()
            try await app.pdfEditor.addFreeText(id: id, pageIndex: src, rect: rect, text: freeTextContent)
            previewImages[src] = nil
            await loadPreview(sourceIndex: src)
            statusMessage = "Added text box."
        } catch { errorMessage = error.localizedDescription }
    }

    private func addSignature() async {
        do {
            let (id, src, rect) = try await annotationRect()
            try await app.pdfEditor.addSignature(id: id, pageIndex: src, rect: rect)
            // Also free text label under signature
            let labelRect = rect.offsetBy(dx: 0, dy: -24)
            try await app.pdfEditor.addFreeText(id: id, pageIndex: src, rect: labelRect, text: signatureName, fontSize: 11)
            previewImages[src] = nil
            await loadPreview(sourceIndex: src)
            statusMessage = "Added signature."
        } catch { errorMessage = error.localizedDescription }
    }

    private func addStamp() async {
        do {
            let (id, src, rect) = try await annotationRect()
            try await app.pdfEditor.addStamp(id: id, pageIndex: src, rect: rect, text: annotationText)
            previewImages[src] = nil
            await loadPreview(sourceIndex: src)
            statusMessage = "Added stamp."
        } catch { errorMessage = error.localizedDescription }
    }

    private func addWatermark() async {
        guard let id = pdfSessionID else { return }
        do {
            try await app.pdfEditor.addWatermarkText(id: id, text: watermarkText)
            previewImages = [:]
            await refreshPDFSnapshot()
            statusMessage = "Watermarked all pages."
        } catch { errorMessage = error.localizedDescription }
    }

    private func clearAnnotations() async {
        guard let id = pdfSessionID, let src = currentSourceIndex() else { return }
        do {
            try await app.pdfEditor.clearAnnotations(id: id, pageIndex: src)
            previewImages[src] = nil
            await loadPreview(sourceIndex: src)
            statusMessage = "Cleared annotations on page \(selectedPage + 1)."
        } catch { errorMessage = error.localizedDescription }
    }

    // MARK: - Image actions

    private func applyImageEdits() async {
        guard let original = imageOriginal else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let crop: CGRect? = cropEnabled ? CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8) : nil
            let size: CGSize? = {
                if resizeWidth > 0, resizeHeight > 0 {
                    return CGSize(width: resizeWidth, height: resizeHeight)
                }
                return nil
            }()
            let adj = ImageEditorService.Adjustments(
                brightness: brightness,
                contrast: contrast,
                saturation: saturation
            )
            let result = try await app.imageEditor.apply(
                image: original,
                cropNormalized: crop,
                targetSize: size,
                adjustments: adj
            )
            imageWorking = result
            imageDirty = true
            statusMessage = "Applied image edits."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func resetImage() {
        imageWorking = imageOriginal
        brightness = 0
        contrast = 1
        saturation = 1
        cropEnabled = false
        if let imageOriginal {
            resizeWidth = Double(imageOriginal.size.width)
            resizeHeight = Double(imageOriginal.size.height)
        }
        imageDirty = false
        statusMessage = "Reset image edits."
    }
}
