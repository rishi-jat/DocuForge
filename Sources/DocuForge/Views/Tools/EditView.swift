import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PDFKit
import Combine
import DocuForgeCore

/// Document editor — PDF canvas + screenshot text rewrite (OCR).
struct EditView: View {
    @EnvironmentObject private var app: AppModel

    enum Mode: String {
        case none, pdf, text, image
    }

    @State private var mode: Mode = .none
    @State private var sourceURL: URL?
    @StateObject private var pdfSessionHolder = PDFSessionHolder()
    @State private var statusMessage = ""
    @State private var errorMessage = ""
    @State private var isBusy = false

    // Text mode
    @State private var textDocument: TextEditorService.TextDocument?
    @State private var textBody = ""
    @State private var textDirty = false
    @State private var findText = ""
    @State private var replaceText = ""
    @State private var caseSensitive = false

    // Image / screenshot text mode
    @State private var imageOriginal: NSImage?
    @State private var imageWorking: NSImage?
    @State private var imageFormat: DocumentFormat = .png
    @State private var imageDirty = false
    @State private var shotBlocks: [ScreenshotTextEditorService.TextBlock] = []
    @State private var shotBusy = false
    @State private var shotFind = ""
    @State private var shotReplace = ""
    @State private var shotStatus = ""

    // PDF page image adjust sheet
    @State private var sheetBrightness: Double = 0
    @State private var sheetContrast: Double = 1
    @State private var sheetSaturation: Double = 1
    @State private var sheetCrop = false
    @State private var sheetPreview: NSImage?

    // PDF screenshot-text sheet state
    @State private var pdfShotBlocks: [ScreenshotTextEditorService.TextBlock] = []
    @State private var pdfShotBusy = false
    @State private var pdfShotFind = ""
    @State private var pdfShotReplace = ""
    @State private var pdfShotStatus = ""
    @State private var pdfShotWorking: NSImage?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if !statusMessage.isEmpty || !errorMessage.isEmpty {
                statusLine
            }
            Divider()
            Group {
                switch mode {
                case .none: emptyState
                case .pdf:
                    if let session = pdfSessionHolder.session {
                        // Critical: observe the session itself so click/find updates refresh UI
                        PDFEditorWorkspace(
                            session: session,
                            statusMessage: $statusMessage,
                            errorMessage: $errorMessage,
                            onOpenScreenshotText: { openPDFScreenshotTextEditor() },
                            onOpenPageImage: { openPageImageEditor() }
                        )
                    } else {
                        Text("No PDF session").foregroundStyle(.secondary)
                    }
                case .text: textWorkspace
                case .image: imageScreenshotWorkspace
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: Binding(
            get: { pdfSessionHolder.session?.showPageImageEditor == true },
            set: { if !$0 { pdfSessionHolder.session?.showPageImageEditor = false } }
        )) {
            pageImageEditorSheet
        }
        .sheet(isPresented: Binding(
            get: { pdfSessionHolder.session?.showScreenshotTextEditor == true },
            set: { if !$0 { pdfSessionHolder.session?.showScreenshotTextEditor = false } }
        )) {
            pdfScreenshotTextSheet
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Label(modeTitle, systemImage: modeIcon)
                .font(.headline)

            if let name = sourceURL?.lastPathComponent {
                Text(name).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }

            Spacer()

            if mode == .pdf, let session = pdfSessionHolder.session {
                Button {
                    session.rotateCurrentPage(90)
                    statusMessage = session.status
                } label: { Image(systemName: "rotate.right") }
                .help("Rotate page")

                Button {
                    session.insertBlankPage()
                    statusMessage = session.status
                } label: { Image(systemName: "doc.badge.plus") }
                .help("Insert blank page")

                Button(role: .destructive) {
                    session.deleteCurrentPage()
                    statusMessage = session.status
                } label: { Image(systemName: "trash") }
                .help("Delete page")
            }

            if mode != .none {
                Button("Close") { closeSession() }
                Button("Save As…") { Task { await saveAs() } }
                Button("Save") { Task { await save() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(isBusy)
            } else {
                Button("Open…") {
                    let urls = app.pickFiles(contentTypes: [.item], allowsMultiple: false)
                    if let url = urls.first { Task { await open(url) } }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var modeTitle: String {
        switch mode {
        case .none: return "Edit"
        case .pdf: return "PDF Editor"
        case .text: return "Text Editor"
        case .image: return "Screenshot text editor"
        }
    }

    private var modeIcon: String {
        switch mode {
        case .none: return "pencil.and.outline"
        case .pdf: return "doc.richtext"
        case .text: return "doc.plaintext"
        case .image: return "text.viewfinder"
        }
    }

    private var statusLine: some View {
        HStack {
            if !errorMessage.isEmpty {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            } else {
                Text(statusMessage).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(errorMessage.isEmpty ? Color.clear : Color.red.opacity(0.08))
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: 20) {
            DropZoneView(
                title: "Open a file to edit",
                subtitle: "PDF: click words or use Find/Replace. Screenshot / PNG / JPEG: detect text with OCR and rewrite words inside the image. Office files open as PDF for layout-safe editing.",
                systemImage: "doc.badge.plus",
                allowedTypes: [.item],
                allowsMultiple: false
            ) { urls in
                if let url = urls.first { Task { await open(url) } }
            }
            .frame(maxWidth: 640)

            HStack(spacing: 16) {
                tip("Main feature: text in screenshots", "Paste or open a screenshot → Detect text → change any line → Apply. Works on pixels, not only PDF text layers.")
                tip("PDF text (Pages-style)", "Double-click a word → type on the page → Return. Drag words then Highlight.")
                tip("Scanned PDFs", "No text layer? Use “Edit text in screenshot” on the page — OCR rewrites the words in the page image.")
            }
            .frame(maxWidth: 980)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func tip(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(body).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    // MARK: - Image / screenshot workspace (MAIN FEATURE)

    private var imageScreenshotWorkspace: some View {
        HSplitView {
            VStack(spacing: 12) {
                if let imageWorking {
                    Image(nsImage: imageWorking)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(8)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .overlay(alignment: .topLeading) {
                            // Draw detected boxes
                            GeometryReader { geo in
                                let size = imageWorking.size
                                let scale = min(geo.size.width / max(size.width, 1), geo.size.height / max(size.height, 1))
                                let drawW = size.width * scale
                                let drawH = size.height * scale
                                let ox = (geo.size.width - drawW) / 2
                                let oy = (geo.size.height - drawH) / 2
                                ForEach(shotBlocks) { block in
                                    let r = block.pixelBounds
                                    Rectangle()
                                        .stroke(block.isModified ? Color.orange : Color.accentColor, lineWidth: 1.5)
                                        .frame(width: r.width * scale, height: r.height * scale)
                                        .position(
                                            x: ox + (r.midX) * scale,
                                            y: oy + (r.midY) * scale
                                        )
                                }
                            }
                            .padding(8)
                        }
                } else {
                    ContentUnavailableView("No image", systemImage: "photo", description: Text("Paste a screenshot or open an image."))
                }
            }
            .frame(minWidth: 360)

            VStack(alignment: .leading, spacing: 12) {
                Text("Edit text inside screenshot").font(.title3.weight(.bold))
                Text("This reads words drawn in the picture (OCR), then covers the old pixels and writes your new text. The file stays an image (or paste back into a PDF page).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button {
                        pasteScreenshotToImageMode()
                    } label: {
                        Label("Paste screenshot", systemImage: "doc.on.clipboard")
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        Task { await detectShotText() }
                    } label: {
                        Label(shotBusy ? "Detecting…" : "Detect text", systemImage: "text.viewfinder")
                    }
                    .disabled(imageWorking == nil || shotBusy)

                    Button {
                        Task { await applyShotEdits() }
                    } label: {
                        Label("Apply text changes", systemImage: "checkmark.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(shotBlocks.allSatisfy { !$0.isModified } || shotBusy)
                }

                HStack {
                    TextField("Find in detected text", text: $shotFind)
                        .textFieldStyle(.roundedBorder)
                    TextField("Replace with", text: $shotReplace)
                        .textFieldStyle(.roundedBorder)
                    Button("Replace in list") {
                        applyShotFindReplaceToBlocks()
                    }
                    .disabled(shotFind.isEmpty || shotBlocks.isEmpty)
                }

                if !shotStatus.isEmpty {
                    Text(shotStatus).font(.caption).foregroundStyle(.secondary)
                }

                if shotBlocks.isEmpty {
                    Text("Click Detect text after pasting a screenshot. Each line becomes editable below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(shotBlocks.count) text region(s) — edit any field, then Apply text changes")
                        .font(.caption.weight(.semibold))
                    List {
                        ForEach($shotBlocks) { $block in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("OCR: \(block.originalText)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                TextField("New text", text: $block.editedText)
                                    .textFieldStyle(.roundedBorder)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .listStyle(.inset)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(minWidth: 340, idealWidth: 380)
        }
        .padding(8)
    }

    // MARK: - Text workspace

    private var textWorkspace: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Find", text: $findText).textFieldStyle(.roundedBorder).frame(maxWidth: 160)
                TextField("Replace", text: $replaceText).textFieldStyle(.roundedBorder).frame(maxWidth: 160)
                Toggle("Aa", isOn: $caseSensitive).toggleStyle(.button)
                Button("Replace All") {
                    Task {
                        let r = await app.textEditor.searchReplace(
                            text: textBody, search: findText, replace: replaceText, caseSensitive: caseSensitive
                        )
                        textBody = r.output
                        textDirty = r.replacedCount > 0
                        statusMessage = "Replaced \(r.replacedCount) occurrence(s)."
                    }
                }
                .buttonStyle(.borderedProminent)
                Spacer()
            }
            .padding(10)
            if let note = textDocument?.limitationNote {
                Text(note).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12)
            }
            TextEditor(text: $textBody)
                .font(.system(size: 14))
                .onChange(of: textBody) { _, _ in textDirty = true }
        }
    }

    // MARK: - PDF sheets

    private var pageImageEditorSheet: some View {
        VStack(spacing: 16) {
            Text("Adjust page image").font(.title2.weight(.bold))
            Text("Brightness / crop only. To change words inside a screenshot page, cancel and use “Edit text in screenshot”.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)

            if let preview = sheetPreview ?? pdfSessionHolder.session?.pageImageForEdit {
                Image(nsImage: preview)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 360)
            }

            HStack { Text("Brightness"); Slider(value: $sheetBrightness, in: -0.4...0.4) }
            HStack { Text("Contrast"); Slider(value: $sheetContrast, in: 0.6...1.5) }
            HStack { Text("Saturation"); Slider(value: $sheetSaturation, in: 0...2) }
            Toggle("Crop 8% margins", isOn: $sheetCrop)
                .onChange(of: sheetBrightness) { _, _ in Task { await refreshSheetPreview() } }
                .onChange(of: sheetContrast) { _, _ in Task { await refreshSheetPreview() } }
                .onChange(of: sheetSaturation) { _, _ in Task { await refreshSheetPreview() } }
                .onChange(of: sheetCrop) { _, _ in Task { await refreshSheetPreview() } }

            HStack {
                Button("Cancel") { pdfSessionHolder.session?.showPageImageEditor = false }
                Spacer()
                Button("Apply to page") { Task { await applySheetImage() } }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(minWidth: 640, minHeight: 560)
        .onAppear {
            sheetPreview = pdfSessionHolder.session?.pageImageForEdit
            Task { await refreshSheetPreview() }
        }
    }

    private var pdfScreenshotTextSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit text in this page (screenshot / OCR)")
                .font(.title2.weight(.bold))
            Text("Detects words drawn on the page image, lets you change them, then writes the page back into the PDF. Other pages stay untouched.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 16) {
                if let img = pdfShotWorking ?? pdfSessionHolder.session?.pageImageForEdit {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 420, maxHeight: 480)
                        .border(Color.primary.opacity(0.12))
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Button {
                            Task { await detectPDFShotText() }
                        } label: {
                            Label(pdfShotBusy ? "Detecting…" : "Detect text", systemImage: "text.viewfinder")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(pdfShotBusy)

                        Button {
                            Task { await applyPDFShotEdits() }
                        } label: {
                            Label("Apply to PDF page", systemImage: "checkmark.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(pdfShotBlocks.allSatisfy { !$0.isModified } || pdfShotBusy)
                    }

                    HStack {
                        TextField("Find", text: $pdfShotFind).textFieldStyle(.roundedBorder)
                        TextField("Replace", text: $pdfShotReplace).textFieldStyle(.roundedBorder)
                        Button("Replace in list") {
                            for i in pdfShotBlocks.indices {
                                if pdfShotBlocks[i].editedText.range(of: pdfShotFind, options: .caseInsensitive) != nil {
                                    pdfShotBlocks[i].editedText = pdfShotBlocks[i].editedText.replacingOccurrences(
                                        of: pdfShotFind, with: pdfShotReplace, options: .caseInsensitive
                                    )
                                }
                            }
                        }
                        .disabled(pdfShotFind.isEmpty)
                    }

                    if !pdfShotStatus.isEmpty {
                        Text(pdfShotStatus).font(.caption).foregroundStyle(.secondary)
                    }

                    if pdfShotBlocks.isEmpty {
                        Text("Press Detect text to list every word/line found on this page image.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        List {
                            ForEach($pdfShotBlocks) { $block in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(block.originalText).font(.caption2).foregroundStyle(.secondary)
                                    TextField("New text", text: $block.editedText).textFieldStyle(.roundedBorder)
                                }
                            }
                        }
                        .frame(minHeight: 280)
                    }
                }
                .frame(minWidth: 320)
            }

            HStack {
                Button("Cancel") {
                    pdfSessionHolder.session?.showScreenshotTextEditor = false
                }
                Spacer()
            }
        }
        .padding(24)
        .frame(minWidth: 900, minHeight: 620)
        .onAppear {
            pdfShotWorking = pdfSessionHolder.session?.pageImageForEdit
            pdfShotBlocks = []
            pdfShotStatus = "Ready — press Detect text."
            Task { await detectPDFShotText() }
        }
    }

    // MARK: - Actions

    private func openPageImageEditor() {
        pdfSessionHolder.session?.beginEditPageAsImage()
        sheetBrightness = 0; sheetContrast = 1; sheetSaturation = 1; sheetCrop = false
        sheetPreview = pdfSessionHolder.session?.pageImageForEdit
    }

    private func openPDFScreenshotTextEditor() {
        pdfSessionHolder.session?.beginScreenshotTextEdit()
        pdfShotWorking = pdfSessionHolder.session?.pageImageForEdit
        pdfShotBlocks = []
        pdfShotStatus = ""
    }

    private func pasteScreenshotToImageMode() {
        if let img = NSImage(pasteboard: .general) {
            Task {
                let norm = await app.screenshotText.normalizedImage(img)
                await MainActor.run {
                    imageOriginal = norm
                    imageWorking = norm
                    imageDirty = true
                    imageFormat = .png
                    shotBlocks = []
                    shotStatus = "Pasted screenshot. Press Detect text."
                    statusMessage = "Screenshot pasted."
                    errorMessage = ""
                }
                await detectShotText()
            }
        } else {
            errorMessage = "Clipboard has no image. Use ⌘⇧4 then copy the capture."
        }
    }

    private func detectShotText() async {
        guard let image = imageWorking else { return }
        shotBusy = true
        defer { shotBusy = false }
        do {
            let norm = await app.screenshotText.normalizedImage(image)
            imageWorking = norm
            let result = try await app.screenshotText.detectText(in: norm)
            shotBlocks = result.blocks
            shotStatus = result.blocks.isEmpty
                ? "No text found. Try a sharper screenshot."
                : "Found \(result.blocks.count) region(s), confidence \(Int(result.averageConfidence * 100))%. Edit below, then Apply."
            statusMessage = shotStatus
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func applyShotFindReplaceToBlocks() {
        guard !shotFind.isEmpty else { return }
        var n = 0
        for i in shotBlocks.indices {
            if shotBlocks[i].editedText.range(of: shotFind, options: .caseInsensitive) != nil {
                shotBlocks[i].editedText = shotBlocks[i].editedText.replacingOccurrences(
                    of: shotFind, with: shotReplace, options: .caseInsensitive
                )
                n += 1
            }
        }
        shotStatus = "Updated \(n) line(s) in the list — press Apply text changes."
    }

    private func applyShotEdits() async {
        guard let image = imageWorking else { return }
        shotBusy = true
        defer { shotBusy = false }
        do {
            let out = try await app.screenshotText.applyEdits(image: image, blocks: shotBlocks)
            imageWorking = out
            imageDirty = true
            // Re-detect so boxes match new image
            let result = try await app.screenshotText.detectText(in: out)
            shotBlocks = result.blocks
            shotStatus = "Applied text changes to screenshot. Save when ready."
            statusMessage = shotStatus
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func detectPDFShotText() async {
        guard let image = pdfSessionHolder.session?.pageImageForEdit ?? pdfShotWorking else {
            pdfShotStatus = "No page image loaded."
            return
        }
        pdfShotBusy = true
        defer { pdfShotBusy = false }
        do {
            let result = try await app.screenshotText.detectText(in: image)
            pdfShotBlocks = result.blocks
            pdfShotWorking = image
            pdfShotStatus = result.blocks.isEmpty
                ? "No text found on this page image."
                : "Found \(result.blocks.count) region(s). Edit text, then Apply to PDF page."
        } catch {
            pdfShotStatus = error.localizedDescription
        }
    }

    private func applyPDFShotEdits() async {
        guard let session = pdfSessionHolder.session,
              let base = session.pageImageForEdit ?? pdfShotWorking else { return }
        pdfShotBusy = true
        defer { pdfShotBusy = false }
        do {
            let out = try await app.screenshotText.applyEdits(image: base, blocks: pdfShotBlocks)
            pdfShotWorking = out
            session.applyEditedPageImage(out)
            statusMessage = session.status
            pdfShotStatus = "Applied to PDF page \(session.currentPageIndex + 1)."
        } catch {
            errorMessage = error.localizedDescription
            pdfShotStatus = error.localizedDescription
        }
    }

    private func refreshSheetPreview() async {
        guard let base = pdfSessionHolder.session?.pageImageForEdit else { return }
        do {
            let crop: CGRect? = sheetCrop ? CGRect(x: 0.08, y: 0.08, width: 0.84, height: 0.84) : nil
            let edited = try await app.imageEditor.apply(
                image: base,
                cropNormalized: crop,
                targetSize: nil,
                adjustments: .init(brightness: sheetBrightness, contrast: sheetContrast, saturation: sheetSaturation)
            )
            await MainActor.run { sheetPreview = edited }
        } catch {
            await MainActor.run { sheetPreview = base }
        }
    }

    private func applySheetImage() async {
        guard let session = pdfSessionHolder.session,
              let base = session.pageImageForEdit else { return }
        do {
            let crop: CGRect? = sheetCrop ? CGRect(x: 0.08, y: 0.08, width: 0.84, height: 0.84) : nil
            let edited = try await app.imageEditor.apply(
                image: base,
                cropNormalized: crop,
                targetSize: nil,
                adjustments: .init(brightness: sheetBrightness, contrast: sheetContrast, saturation: sheetSaturation)
            )
            session.applyEditedPageImage(edited)
            statusMessage = session.status
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Open / save

    private func open(_ url: URL) async {
        errorMessage = ""; statusMessage = ""; isBusy = true
        defer { isBusy = false }
        let format = DocumentFormat.detect(url: url)
        do {
            if format == .pdf {
                let session = try LivePDFSession.open(url: url)
                session.tool = .edit
                pdfSessionHolder.attach(session)
                sourceURL = url
                mode = .pdf
                if session.currentPageHasTextLayer {
                    statusMessage = "\(LivePDFSession.buildLabel). Double-click any word to edit like Pages/Canva. Drag to highlight. Find/Replace All for bulk."
                } else {
                    statusMessage = "PDF has little/no text layer (likely scan/screenshot pages). Use “Edit text in screenshot” to change words."
                }
            } else if format.isImage {
                let img = try await app.imageEditor.load(url: url)
                imageOriginal = img
                imageWorking = img
                imageFormat = format
                imageDirty = false
                shotBlocks = []
                sourceURL = url
                mode = .image
                statusMessage = "Image opened. Press Detect text to edit words inside the screenshot."
                Task { await detectShotText() }
            } else if await app.textEditor.isEditableTextFormat(format) {
                let doc = try await app.textEditor.open(url: url)
                textDocument = doc
                textBody = doc.text
                textDirty = false
                sourceURL = url
                mode = .text
                statusMessage = "Text document opened."
            } else if format.isIWork || format.isOfficeOpenXML || format.isLegacyOffice || format.isOpenDocument {
                statusMessage = "Converting to PDF for editing…"
                let dir = try app.makeOutputDirectory(named: "EditOpen")
                let result = try await app.conversion.convert(url: url, to: .pdf, outputDirectory: dir)
                guard let pdfURL = result.outputURLs.first else {
                    throw DocuForgeError.conversionFailed("Could not create PDF for editing.")
                }
                let session = try LivePDFSession.open(url: pdfURL)
                session.tool = .edit
                pdfSessionHolder.attach(session)
                sourceURL = pdfURL
                mode = .pdf
                statusMessage = "Opened \(format.displayName) as PDF. Click words or use screenshot text editor for image content."
            } else {
                errorMessage = "Can’t open \(format.displayName) for editing. Convert to PDF first."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func closeSession() {
        pdfSessionHolder.attach(nil)
        textDocument = nil; textBody = ""; textDirty = false
        imageOriginal = nil; imageWorking = nil; imageDirty = false
        shotBlocks = []
        sourceURL = nil; mode = .none
        statusMessage = ""; errorMessage = ""
    }

    private func save() async {
        errorMessage = ""
        do {
            switch mode {
            case .pdf:
                guard let session = pdfSessionHolder.session else { return }
                let url = try session.save()
                app.recordOutputs([url])
                statusMessage = session.status
            case .text:
                guard var doc = textDocument else { return }
                doc.text = textBody
                let result = try await app.textEditor.save(doc)
                textDirty = false
                app.recordOutputs(result.outputURLs)
                statusMessage = "Saved."
            case .image:
                guard let image = imageWorking, let url = sourceURL else { return }
                if await app.imageEditor.canSaveNative(format: imageFormat) {
                    _ = try await app.imageEditor.save(image: image, to: url, format: imageFormat)
                } else {
                    let png = url.deletingPathExtension().appendingPathExtension("png")
                    _ = try await app.imageEditor.save(image: image, to: png, format: .png)
                    sourceURL = png
                }
                imageDirty = false
                statusMessage = "Saved screenshot/image."
            case .none: break
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveAs() async {
        guard let sourceURL else { return }
        let format = DocumentFormat.detect(url: sourceURL)
        guard let dest = app.pickSaveURL(name: sourceURL.lastPathComponent, contentType: format.utType) else { return }
        do {
            switch mode {
            case .pdf:
                guard let session = pdfSessionHolder.session else { return }
                _ = try session.save(to: dest)
                self.sourceURL = dest
                statusMessage = "Saved as \(dest.lastPathComponent)"
            case .text:
                guard var doc = textDocument else { return }
                doc.text = textBody
                _ = try await app.textEditor.save(doc, to: dest)
                self.sourceURL = dest
                textDirty = false
            case .image:
                guard let image = imageWorking else { return }
                _ = try await app.imageEditor.save(image: image, to: dest, format: DocumentFormat.detect(url: dest))
                self.sourceURL = dest
                imageDirty = false
            case .none: break
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - PDF workspace (observes session)

private struct PDFEditorWorkspace: View {
    @ObservedObject var session: LivePDFSession
    @Binding var statusMessage: String
    @Binding var errorMessage: String
    var onOpenScreenshotText: () -> Void
    var onOpenPageImage: () -> Void

    @State private var lineDrafts: [Int: String] = [:]

    var body: some View {
        VStack(spacing: 0) {
            // Build stamp — confirms new binary
            HStack {
                Text(LivePDFSession.buildLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Double-click text to edit · Drag to highlight")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Color.accentColor.opacity(0.08))

            findBar
            toolBar
            inlineHintBar
            HStack(spacing: 0) {
                pageThumbs
                Divider()
                PDFCanvasView(session: session)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                pageContentPanel
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .onChange(of: session.status) { _, n in statusMessage = n }
        .onChange(of: session.pageLines) { _, lines in
            var m: [Int: String] = [:]
            for l in lines { m[l.index] = l.text }
            lineDrafts = m
        }
        .onAppear {
            var m: [Int: String] = [:]
            for l in session.pageLines { m[l.index] = l.text }
            lineDrafts = m
        }
    }

    private var findBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
            TextField("Find", text: $session.findQuery)
                .textFieldStyle(.roundedBorder).frame(maxWidth: 140)
            TextField("Replace with", text: $session.replaceQuery)
                .textFieldStyle(.roundedBorder).frame(maxWidth: 140)
            Toggle("Aa", isOn: $session.caseSensitive).toggleStyle(.button)
            Button("Find") { session.refreshFind(); statusMessage = session.status }
            Button("Next") { session.goToNextMatch(); statusMessage = session.status }
            Button("Replace All") {
                session.replaceAllPreservingLayout()
                statusMessage = session.status
            }
            .buttonStyle(.borderedProminent)
            .disabled(session.findQuery.isEmpty)
            if session.matchCount > 0 {
                Text("\(session.matchCount)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onOpenScreenshotText) {
                Label("Screenshot text", systemImage: "text.viewfinder")
            }
            .help("OCR edit for scanned/image pages")
            Button {
                session.pasteScreenshotReplacingPage()
                statusMessage = session.status
            } label: {
                Label("Paste shot", systemImage: "doc.on.clipboard")
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.95))
    }

    private var toolBar: some View {
        HStack(spacing: 8) {
            ForEach(LivePDFSession.Tool.allCases) { tool in
                Button {
                    session.tool = tool
                } label: {
                    Label(tool.title, systemImage: tool.systemImage)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(session.tool == tool ? Color.accentColor.opacity(0.25) : Color(nsColor: .controlBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(session.tool == tool ? Color.accentColor : Color.primary.opacity(0.12))
                        )
                }
                .buttonStyle(.plain)
            }
            if session.tool == .addText {
                TextField("New text", text: $session.textBoxDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
            }
            Spacer()
            if !session.currentPageHasTextLayer {
                Text("Image page — use Screenshot text")
                    .font(.caption2)
                    .padding(4)
                    .background(Color.orange.opacity(0.25))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var inlineHintBar: some View {
        if session.inlineEditActive {
            HStack(spacing: 10) {
                Image(systemName: "character.cursor.ibeam")
                Text("Editing on page — type in the yellow field on the PDF, then Return")
                    .font(.caption.weight(.semibold))
                Spacer()
                Button("Done") {
                    session.commitInlineEdit()
                    statusMessage = session.status
                }
                .buttonStyle(.borderedProminent)
                Button("Cancel") {
                    session.endInlineEdit(commit: false)
                }
            }
            .padding(10)
            .background(Color.yellow.opacity(0.2))
        } else {
            Text(toolHint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
        }
    }

    private var pageThumbs: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(0..<session.pageCount, id: \.self) { i in
                    Button { session.goToPage(i) } label: {
                        Text("\(i + 1)")
                            .font(.caption.weight(.semibold))
                            .frame(width: 44, height: 56)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(session.currentPageIndex == i ? Color.accentColor.opacity(0.25) : Color(nsColor: .controlBackgroundColor))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(session.currentPageIndex == i ? Color.accentColor : Color.primary.opacity(0.15))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
        }
        .frame(width: 64)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    private var pageContentPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Page content").font(.headline)
            Text("Like a Pages outline: edit a line, Apply. Or double-click on the page.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if session.pageLines.isEmpty {
                Text(session.currentPageHasTextLayer ? "Click text on the page to edit." : "No text layer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List {
                    ForEach(session.pageLines) { line in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("~\(Int(line.fontSize))pt")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            HStack {
                                TextField("Line", text: Binding(
                                    get: { lineDrafts[line.index] ?? line.text },
                                    set: { lineDrafts[line.index] = $0 }
                                ))
                                .textFieldStyle(.roundedBorder)
                                Button("Apply") {
                                    session.applyPageLineEdit(line: line, newText: lineDrafts[line.index] ?? line.text)
                                    statusMessage = session.status
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .padding(10)
        .frame(width: 300)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }

    private var footer: some View {
        Text(session.status.isEmpty ? LivePDFSession.buildLabel : session.status)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var toolHint: String {
        switch session.tool {
        case .edit:
            return "Edit text: double-click (or click) a word — a field appears ON the word. Type, press Return. Same idea as Pages/Canva."
        case .highlight:
            return "Highlight: drag across words (yellow mark). Or click one word."
        case .underline:
            return "Underline: drag across words."
        case .strike:
            return "Strike: drag across words."
        case .addText:
            return "Add text: click empty space to place new text (only this tool adds text)."
        case .signature:
            return "Sign: click to place a signature stroke."
        case .select:
            return "Select: drag to select/copy text only."
        }
    }
}

@MainActor
final class PDFSessionHolder: ObservableObject {
    @Published var session: LivePDFSession?
    private var cancellable: AnyCancellable?

    func attach(_ newSession: LivePDFSession?) {
        if let newSession {
            cancellable = newSession.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        } else {
            cancellable = nil
        }
        session = newSession
    }
}
