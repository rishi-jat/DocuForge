import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PDFKit
import DocuForgeCore

/// Production editor workspace with stable, full-height layout.
struct EditView: View {
    @EnvironmentObject private var app: AppModel

    enum Mode: String {
        case none, pdf, text, image
    }

    enum PDFTab: String, CaseIterable, Identifiable {
        case content = "Content"
        case pages = "Pages"
        case annotate = "Annotate"
        case screenshots = "Screenshots"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .none
    @State private var sourceURL: URL?
    @State private var statusMessage = ""
    @State private var errorMessage = ""
    @State private var isBusy = false

    @State private var findText = ""
    @State private var replaceText = ""
    @State private var caseSensitive = false
    @State private var matchCount = 0

    @State private var pdfSessionID: UUID?
    @State private var pdfSnapshot: PDFEditorService.SessionSnapshot?
    @State private var selectedPage = 0
    @State private var pageOrder: [Int] = []
    @State private var freeTextContent = "Type here…"
    @State private var watermarkText = "CONFIDENTIAL"
    @State private var previewImages: [Int: NSImage] = [:]
    @State private var pdfTab: PDFTab = .content

    @State private var textDocument: TextEditorService.TextDocument?
    @State private var textBody = ""
    @State private var textDirty = false

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
        VStack(spacing: 0) {
            Text("DocuForge UI · Build UI-VERIFY-233406 · if you see this, you have the new build")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.black)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.yellow)
                .accessibilityLabel("DocuForge UI build banner")

            topBar
            statusBanner
            Divider()

            Group {
                switch mode {
                case .none:
                    emptyState
                case .text:
                    VStack(spacing: 0) {
                        findReplaceBar
                        Divider()
                        textWorkspace
                    }
                case .pdf:
                    VStack(spacing: 0) {
                        findReplaceBar
                        Divider()
                        pdfWorkspace
                    }
                case .image:
                    imageWorkspace
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Top chrome

    private var topBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "pencil.and.outline")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.accentColor))

            VStack(alignment: .leading, spacing: 2) {
                Text("Edit")
                    .font(.title2.weight(.bold))
                Text(mode == .none
                     ? "Open a document and change its content — text, pages, or screenshots."
                     : fileSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            if isBusy {
                ProgressView()
                    .controlSize(.small)
            }

            if mode != .none {
                Button("Close") { closeSession() }
                    .keyboardShortcut(.cancelAction)
                Button("Save As…") { Task { await saveAs() } }
                    .disabled(isBusy)
                Button("Save") { Task { await save() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(isBusy || !canSave)
                    .keyboardShortcut("s", modifiers: .command)
            } else {
                Button("Open…") {
                    let urls = app.pickFiles(contentTypes: [.item], allowsMultiple: false)
                    if let url = urls.first { Task { await open(url) } }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private var statusBanner: some View {
        if !statusMessage.isEmpty || !errorMessage.isEmpty {
            HStack(alignment: .top, spacing: 10) {
                if !statusMessage.isEmpty {
                    Label(statusMessage, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                if !errorMessage.isEmpty {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
                Spacer(minLength: 0)
                Button {
                    statusMessage = ""
                    errorMessage = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .font(.caption)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(errorMessage.isEmpty ? Color.green.opacity(0.08) : Color.red.opacity(0.08))
        }
    }

    private var fileSubtitle: String {
        let name = sourceURL?.lastPathComponent ?? "Document"
        switch mode {
        case .pdf: return "\(name) · PDF · pages, text replace, annotations, screenshots"
        case .text: return "\(name) · \(textDocument?.format.displayName ?? "Text") · find & replace all"
        case .image: return "\(name) · screenshot & image tools"
        case .none: return ""
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

    // MARK: - Empty

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 24) {
                Text("Build UI-VERIFY-233406")
                    .font(.caption.monospaced())
                    .foregroundStyle(Color.accentColor)

                DropZoneView(
                    title: "Drop a file to start editing",
                    subtitle: "PDF · Word · Pages · PowerPoint · Keynote · text · screenshots & images",
                    systemImage: "doc.badge.plus",
                    allowedTypes: [.item],
                    allowsMultiple: false
                ) { urls in
                    if let url = urls.first { Task { await open(url) } }
                }
                .frame(maxWidth: 640)

                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12)
                    ],
                    spacing: 12
                ) {
                    featureCard("Find & replace", "Change every occurrence of a word in one step", "magnifyingglass")
                    featureCard("Keep layout", "Convert with Pages/Keynote when installed so slides don’t break", "rectangle.3.group")
                    featureCard("Screenshots", "Paste or edit screenshots inside PDFs and image files", "camera.viewfinder")
                }
                .frame(maxWidth: 900)
            }
            .padding(28)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func featureCard(_ title: String, _ body: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
            Text(body)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 90, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    // MARK: - Find & replace

    private var findReplaceBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Find", text: $findText)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 120, maxWidth: 220)
                    .onChange(of: findText) { _, _ in Task { await refreshMatchCount() } }

                TextField("Replace with", text: $replaceText)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 120, maxWidth: 220)

                Toggle("Aa", isOn: $caseSensitive)
                    .toggleStyle(.button)
                    .help("Case sensitive")
                    .onChange(of: caseSensitive) { _, _ in Task { await refreshMatchCount() } }

                Text(matchLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 72, alignment: .leading)

                Button("Replace All") { Task { await replaceAll() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(findText.isEmpty || isBusy || matchCount == 0)
                    .keyboardShortcut("r", modifiers: [.command, .option])

                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }

    private var matchLabel: String {
        if findText.isEmpty { return "" }
        return matchCount == 0 ? "No matches" : "\(matchCount) match\(matchCount == 1 ? "" : "es")"
    }

    // MARK: - Text

    private var textWorkspace: some View {
        VStack(spacing: 0) {
            if let note = textDocument?.limitationNote {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle.fill")
                    Text(note)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.1))
            }

            TextEditor(text: $textBody)
                .font(.system(size: 14))
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onChange(of: textBody) { _, _ in
                    textDirty = true
                    Task { await refreshMatchCount() }
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - PDF

    private var pdfWorkspace: some View {
        VStack(spacing: 0) {
            Picker("PDF tools", selection: $pdfTab) {
                ForEach(PDFTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            HStack(spacing: 0) {
                // Page strip
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(Array(pageOrder.enumerated()), id: \.offset) { displayIndex, sourceIndex in
                            pageThumb(displayIndex: displayIndex, sourceIndex: sourceIndex)
                        }
                    }
                    .padding(10)
                }
                .frame(width: 148)
                .frame(maxHeight: .infinity)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        switch pdfTab {
                        case .content: pdfContentPanel
                        case .pages: pdfPagesPanel
                        case .annotate: pdfAnnotatePanel
                        case .screenshots: pdfScreenshotPanel
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var pdfContentPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit written content")
                .font(.headline)
            Text("Use Find & Replace above to change a word everywhere it appears. Text pages are rebuilt so wording stays correct; decorative layout may change for design-heavy PDFs.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox("Selected page \(selectedPage + 1) of \(max(pageOrder.count, 1))") {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Text box content", text: $freeTextContent)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Add text box") { Task { await addFreeText() } }
                        Button("Highlight band") { Task { await addHighlight() } }
                    }
                }
                .padding(8)
            }
        }
    }

    private var pdfPagesPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Page structure")
                .font(.headline)
            HStack {
                Button("Rotate −90°") { Task { await rotate(-90) } }
                Button("Rotate +90°") { Task { await rotate(90) } }
                Button("Delete page", role: .destructive) { Task { await deleteSelected() } }
            }
            HStack {
                Button("Move up") { Task { await moveSelected(delta: -1) } }
                Button("Move down") { Task { await moveSelected(delta: 1) } }
                Button("Insert blank") { Task { await insertBlank() } }
            }
            Text("Reorder pages without exporting. Changes save into the same PDF.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var pdfAnnotatePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Annotations")
                .font(.headline)
            HStack {
                Button("Highlight") { Task { await addHighlight() } }
                Button("Underline") { Task { await addUnderline() } }
                Button("Strike") { Task { await addStrike() } }
                Button("Signature") { Task { await addSignature() } }
            }
            HStack {
                TextField("Watermark text", text: $watermarkText)
                    .textFieldStyle(.roundedBorder)
                Button("Watermark all pages") { Task { await addWatermark() } }
            }
            Button("Clear annotations on this page", role: .destructive) {
                Task { await clearAnnotations() }
            }
        }
    }

    private var pdfScreenshotPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Screenshots in this file")
                .font(.headline)
            Text("Paste a screenshot from the clipboard, or replace the current page with an edited image.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                Button {
                    Task { await pasteScreenshotAsPage() }
                } label: {
                    Label("Paste screenshot as new page", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    Task { await replacePageWithClipboard() }
                } label: {
                    Label("Replace page with clipboard", systemImage: "photo.on.rectangle.angled")
                }

                Button {
                    Task { await exportPageForEditing() }
                } label: {
                    Label("Export this page as PNG…", systemImage: "square.and.arrow.up")
                }

                Button {
                    Task { await insertImageFile() }
                } label: {
                    Label("Insert image file as page…", systemImage: "photo.badge.plus")
                }
            }
        }
    }

    private func pageThumb(displayIndex: Int, sourceIndex: Int) -> some View {
        let selected = selectedPage == displayIndex
        return VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .frame(width: 112, height: 140)
                if let img = previewImages[sourceIndex] {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 100, height: 128)
                } else {
                    ProgressView().controlSize(.mini)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: selected ? 2 : 1)
            )
            Text("\(displayIndex + 1)")
                .font(.caption2)
        }
        .contentShape(Rectangle())
        .onTapGesture { selectedPage = displayIndex }
        .onAppear { Task { await loadPreview(sourceIndex: sourceIndex) } }
    }

    // MARK: - Image

    private var imageWorkspace: some View {
        GeometryReader { geo in
            let sideBySide = geo.size.width > 760
            let stack = sideBySide
                ? AnyView(HStack(alignment: .top, spacing: 20) { imagePreviewPane; imageControlsPane })
                : AnyView(VStack(alignment: .leading, spacing: 16) { imagePreviewPane; imageControlsPane })
            ScrollView {
                stack
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var imagePreviewPane: some View {
        VStack(spacing: 12) {
            if let imageWorking {
                Image(nsImage: imageWorking)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 520, maxHeight: 420)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .frame(height: 240)
                    .overlay(Text("No image").foregroundStyle(.secondary))
            }
            HStack {
                Button {
                    Task { await pasteIntoImageEditor() }
                } label: {
                    Label("Paste screenshot", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.borderedProminent)
                Button("Reset") { resetImage() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var imageControlsPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let imageLimitation {
                Text(imageLimitation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            GroupBox("Adjust") {
                VStack(spacing: 8) {
                    sliderRow("Brightness", $brightness, -0.5...0.5)
                    sliderRow("Contrast", $contrast, 0.5...1.5)
                    sliderRow("Saturation", $saturation, 0...2)
                }
                .padding(8)
            }
            GroupBox("Size & crop") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Crop 10% margins", isOn: $cropEnabled)
                    HStack {
                        TextField("W", value: $resizeWidth, format: .number)
                            .frame(width: 80)
                            .textFieldStyle(.roundedBorder)
                        Text("×")
                        TextField("H", value: $resizeHeight, format: .number)
                            .frame(width: 80)
                            .textFieldStyle(.roundedBorder)
                    }
                    Button("Apply edits") { Task { await applyImageEdits() } }
                        .buttonStyle(.borderedProminent)
                }
                .padding(8)
            }
            Text("Save writes back to \(imageFormat.displayName) when supported.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 260, maxWidth: 320, alignment: .leading)
    }

    private func sliderRow(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title).frame(width: 80, alignment: .leading)
            Slider(value: value, in: range)
        }
    }

    // MARK: - Open / save / actions (logic)

    private func open(_ url: URL) async {
        errorMessage = ""; statusMessage = ""; isBusy = true
        defer { isBusy = false }
        let format = DocumentFormat.detect(url: url)
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
                pdfTab = .content
                statusMessage = "Opened PDF. Use Find to change wording, or Screenshots to edit captures."
                await refreshMatchCount()
            } else if format.isImage {
                let img = try await app.imageEditor.load(url: url)
                imageOriginal = img
                imageWorking = img
                imageFormat = format
                resizeWidth = Double(img.size.width)
                resizeHeight = Double(img.size.height)
                brightness = 0; contrast = 1; saturation = 1
                cropEnabled = false; imageDirty = false
                sourceURL = url
                mode = .image
                imageLimitation = (format == .svg || format == .psd)
                    ? "\(format.displayName) has limited write support — Save may write PNG instead."
                    : nil
                statusMessage = "Opened image. Paste screenshots or adjust and Save."
            } else if await app.textEditor.isEditableTextFormat(format) {
                let doc = try await app.textEditor.open(url: url)
                textDocument = doc
                textBody = doc.text
                textDirty = false
                sourceURL = url
                mode = .text
                statusMessage = "Opened \(doc.format.displayName). Find & Replace All works across the whole file."
                await refreshMatchCount()
            } else if format.isIWork || format.isOfficeOpenXML || format.isLegacyOffice || format.isOpenDocument {
                errorMessage = "\(format.displayName) is best opened via Convert → PDF (uses Pages/Keynote when available so layout stays intact), then edit that PDF here. Or convert to DOCX/TXT to edit wording with Find & Replace."
            } else {
                errorMessage = "No direct editor for \(format.displayName). Convert to PDF, TXT, or an image first."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func closeSession() {
        if let id = pdfSessionID { Task { await app.pdfEditor.close(id: id) } }
        pdfSessionID = nil; pdfSnapshot = nil; pageOrder = []; previewImages = [:]
        textDocument = nil; textBody = ""; textDirty = false
        imageOriginal = nil; imageWorking = nil; imageDirty = false
        sourceURL = nil; mode = .none
        findText = ""; replaceText = ""; matchCount = 0
        statusMessage = ""; errorMessage = ""
    }

    private func save() async {
        errorMessage = ""; isBusy = true; defer { isBusy = false }
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
                textDocument = doc; textDirty = false
                app.recordOutputs(result.outputURLs)
                statusMessage = result.notes.isEmpty ? "Saved." : result.notes.joined(separator: " ")
            case .image:
                guard let image = imageWorking, let url = sourceURL else { return }
                if await app.imageEditor.canSaveNative(format: imageFormat) {
                    let result = try await app.imageEditor.save(image: image, to: url, format: imageFormat)
                    app.recordOutputs(result.outputURLs)
                    imageDirty = false
                    statusMessage = "Saved \(url.lastPathComponent)."
                } else {
                    let pngURL = url.deletingPathExtension().appendingPathExtension("png")
                    let result = try await app.imageEditor.save(image: image, to: pngURL, format: .png)
                    app.recordOutputs(result.outputURLs)
                    imageDirty = false
                    statusMessage = "Saved PNG instead (format limitation): \(pngURL.lastPathComponent)"
                }
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
        errorMessage = ""; isBusy = true; defer { isBusy = false }
        do {
            switch mode {
            case .pdf:
                guard let id = pdfSessionID else { return }
                _ = try await app.pdfEditor.saveAs(id: id, url: dest)
                self.sourceURL = dest
                statusMessage = "Saved as \(dest.lastPathComponent)."
            case .text:
                guard var doc = textDocument else { return }
                doc.text = textBody
                _ = try await app.textEditor.save(doc, to: dest)
                textDocument?.sourceURL = dest
                textDirty = false
                self.sourceURL = dest
                statusMessage = "Saved as \(dest.lastPathComponent)."
            case .image:
                guard let image = imageWorking else { return }
                _ = try await app.imageEditor.save(image: image, to: dest, format: DocumentFormat.detect(url: dest))
                self.sourceURL = dest
                imageDirty = false
                statusMessage = "Saved as \(dest.lastPathComponent)."
            case .none: break
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refreshMatchCount() async {
        guard !findText.isEmpty else { matchCount = 0; return }
        switch mode {
        case .text:
            matchCount = await app.textEditor.countMatches(text: textBody, search: findText, caseSensitive: caseSensitive)
        case .pdf:
            guard let id = pdfSessionID else { matchCount = 0; return }
            do {
                matchCount = try await app.pdfEditor.countTextMatches(id: id, search: findText, caseSensitive: caseSensitive)
            } catch { matchCount = 0 }
        default:
            matchCount = 0
        }
    }

    private func replaceAll() async {
        errorMessage = ""; isBusy = true; defer { isBusy = false }
        do {
            switch mode {
            case .text:
                let result = await app.textEditor.searchReplace(
                    text: textBody, search: findText, replace: replaceText, caseSensitive: caseSensitive
                )
                textBody = result.output
                textDirty = result.replacedCount > 0
                matchCount = 0
                statusMessage = result.replacedCount == 0 ? "No matches." : "Replaced \(result.replacedCount) occurrence(s)."
            case .pdf:
                guard let id = pdfSessionID else { return }
                let result = try await app.pdfEditor.replaceAllText(
                    id: id, search: findText, replace: replaceText, caseSensitive: caseSensitive
                )
                matchCount = 0
                statusMessage = result.notes.joined(separator: " ")
                await refreshPDFSnapshot()
            default: break
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refreshPDFSnapshot() async {
        guard let id = pdfSessionID else { return }
        do {
            let snap = try await app.pdfEditor.snapshot(id: id)
            pdfSnapshot = snap
            pageOrder = Array(0..<snap.pageCount)
            previewImages = [:]
            if selectedPage >= snap.pageCount { selectedPage = max(0, snap.pageCount - 1) }
            for i in pageOrder.prefix(16) { await loadPreview(sourceIndex: i) }
            await refreshMatchCount()
        } catch { errorMessage = error.localizedDescription }
    }

    private func loadPreview(sourceIndex: Int) async {
        guard let id = pdfSessionID, previewImages[sourceIndex] == nil else { return }
        if let data = try? await app.pdfEditor.pagePreview(id: id, pageIndex: sourceIndex),
           let img = NSImage(data: data) {
            previewImages[sourceIndex] = img
        }
    }

    private func currentSourceIndex() -> Int? {
        guard selectedPage >= 0, selectedPage < pageOrder.count else { return nil }
        return pageOrder[selectedPage]
    }

    private func rotate(_ d: Int) async {
        guard let id = pdfSessionID, let src = currentSourceIndex() else { return }
        do {
            try await app.pdfEditor.rotatePage(id: id, pageIndex: src, degrees: d)
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
        guard pageOrder.indices.contains(to) else { return }
        var order = pageOrder
        order.swapAt(from, to)
        do {
            try await app.pdfEditor.reorderPages(id: id, orderedIndices: order)
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

    private func annotationRect() async throws -> (UUID, Int, CGRect) {
        guard let id = pdfSessionID, let src = currentSourceIndex() else {
            throw DocuForgeError.invalidInput("Select a page first.")
        }
        let bounds = try await app.pdfEditor.pageBounds(id: id, pageIndex: src)
        let rect = CGRect(x: bounds.width * 0.15, y: bounds.height * 0.45, width: bounds.width * 0.7, height: bounds.height * 0.1)
        return (id, src, rect)
    }

    private func addHighlight() async {
        do {
            let (id, src, rect) = try await annotationRect()
            try await app.pdfEditor.addHighlight(id: id, pageIndex: src, rect: rect)
            previewImages[src] = nil; await loadPreview(sourceIndex: src)
            statusMessage = "Added highlight."
        } catch { errorMessage = error.localizedDescription }
    }
    private func addUnderline() async {
        do {
            let (id, src, rect) = try await annotationRect()
            try await app.pdfEditor.addUnderline(id: id, pageIndex: src, rect: rect)
            previewImages[src] = nil; await loadPreview(sourceIndex: src)
            statusMessage = "Added underline."
        } catch { errorMessage = error.localizedDescription }
    }
    private func addStrike() async {
        do {
            let (id, src, rect) = try await annotationRect()
            try await app.pdfEditor.addStrikethrough(id: id, pageIndex: src, rect: rect)
            previewImages[src] = nil; await loadPreview(sourceIndex: src)
            statusMessage = "Added strikethrough."
        } catch { errorMessage = error.localizedDescription }
    }
    private func addFreeText() async {
        do {
            let (id, src, rect) = try await annotationRect()
            try await app.pdfEditor.addFreeText(id: id, pageIndex: src, rect: rect, text: freeTextContent)
            previewImages[src] = nil; await loadPreview(sourceIndex: src)
            statusMessage = "Added text box."
        } catch { errorMessage = error.localizedDescription }
    }
    private func addSignature() async {
        do {
            let (id, src, rect) = try await annotationRect()
            try await app.pdfEditor.addSignature(id: id, pageIndex: src, rect: rect)
            previewImages[src] = nil; await loadPreview(sourceIndex: src)
            statusMessage = "Added signature."
        } catch { errorMessage = error.localizedDescription }
    }
    private func addWatermark() async {
        guard let id = pdfSessionID else { return }
        do {
            try await app.pdfEditor.addWatermarkText(id: id, text: watermarkText)
            await refreshPDFSnapshot()
            statusMessage = "Watermark applied to all pages."
        } catch { errorMessage = error.localizedDescription }
    }
    private func clearAnnotations() async {
        guard let id = pdfSessionID, let src = currentSourceIndex() else { return }
        do {
            try await app.pdfEditor.clearAnnotations(id: id, pageIndex: src)
            previewImages[src] = nil; await loadPreview(sourceIndex: src)
            statusMessage = "Cleared annotations."
        } catch { errorMessage = error.localizedDescription }
    }

    private func pasteScreenshotAsPage() async {
        guard let id = pdfSessionID else { return }
        guard let image = await app.imageEditor.clipboardImage() else {
            errorMessage = "Clipboard has no image. Take a screenshot (⌘⇧4) and copy it, then try again."
            return
        }
        do {
            try await app.pdfEditor.insertScreenshotPage(id: id, after: selectedPage, image: image)
            await refreshPDFSnapshot()
            statusMessage = "Pasted screenshot as a new page."
        } catch { errorMessage = error.localizedDescription }
    }

    private func replacePageWithClipboard() async {
        guard let id = pdfSessionID, let src = currentSourceIndex() else { return }
        guard let image = await app.imageEditor.clipboardImage() else {
            errorMessage = "Clipboard has no image."
            return
        }
        do {
            try await app.pdfEditor.replacePageWithImage(id: id, pageIndex: src, image: image)
            previewImages[src] = nil
            await loadPreview(sourceIndex: src)
            statusMessage = "Replaced page \(selectedPage + 1) with clipboard image."
        } catch { errorMessage = error.localizedDescription }
    }

    private func exportPageForEditing() async {
        guard let id = pdfSessionID, let src = currentSourceIndex() else { return }
        do {
            let data = try await app.pdfEditor.exportPageImage(id: id, pageIndex: src)
            let dir = try app.makeOutputDirectory(named: "PageExport")
            let out = dir.appendingPathComponent("page-\(selectedPage + 1).png")
            try data.write(to: out)
            app.recordOutputs([out])
            statusMessage = "Exported page PNG — edit it, copy, then Replace page with clipboard."
            app.revealInFinder(out)
        } catch { errorMessage = error.localizedDescription }
    }

    private func insertImageFile() async {
        guard let id = pdfSessionID else { return }
        let urls = app.pickFiles(contentTypes: [.image], allowsMultiple: false)
        guard let url = urls.first else { return }
        do {
            try await app.pdfEditor.insertImagePage(id: id, imageURL: url, at: selectedPage + 1)
            await refreshPDFSnapshot()
            statusMessage = "Inserted image page."
        } catch { errorMessage = error.localizedDescription }
    }

    private func pasteIntoImageEditor() async {
        guard let image = await app.imageEditor.clipboardImage() else {
            errorMessage = "Clipboard has no image."
            return
        }
        imageOriginal = image
        imageWorking = image
        imageFormat = .png
        resizeWidth = Double(image.size.width)
        resizeHeight = Double(image.size.height)
        imageDirty = true
        if sourceURL == nil {
            sourceURL = FileIO.temporaryURL(prefix: "screenshot", ext: "png")
        }
        statusMessage = "Pasted screenshot into the image editor."
    }

    private func applyImageEdits() async {
        guard let original = imageOriginal else { return }
        isBusy = true; defer { isBusy = false }
        do {
            let crop: CGRect? = cropEnabled ? CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8) : nil
            let size: CGSize? = (resizeWidth > 0 && resizeHeight > 0) ? CGSize(width: resizeWidth, height: resizeHeight) : nil
            let result = try await app.imageEditor.apply(
                image: original,
                cropNormalized: crop,
                targetSize: size,
                adjustments: .init(brightness: brightness, contrast: contrast, saturation: saturation)
            )
            imageWorking = result
            imageDirty = true
            statusMessage = "Applied image edits."
        } catch { errorMessage = error.localizedDescription }
    }

    private func resetImage() {
        imageWorking = imageOriginal
        brightness = 0; contrast = 1; saturation = 1; cropEnabled = false
        if let imageOriginal {
            resizeWidth = Double(imageOriginal.size.width)
            resizeHeight = Double(imageOriginal.size.height)
        }
        imageDirty = false
        statusMessage = "Reset."
    }
}
