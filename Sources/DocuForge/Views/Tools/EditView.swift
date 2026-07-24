import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PDFKit
import DocuForgeCore

/// Production editor workspace: open a file and change its content like a document app —
/// find/replace, pages, annotations, screenshots — with clear save-back behavior.
struct EditView: View {
    @EnvironmentObject private var app: AppModel

    enum Mode: String {
        case none, pdf, text, image
    }

    @State private var mode: Mode = .none
    @State private var sourceURL: URL?
    @State private var statusMessage = ""
    @State private var errorMessage = ""
    @State private var isBusy = false

    // Find & replace (shared)
    @State private var findText = ""
    @State private var replaceText = ""
    @State private var caseSensitive = false
    @State private var matchCount = 0

    // PDF
    @State private var pdfSessionID: UUID?
    @State private var pdfSnapshot: PDFEditorService.SessionSnapshot?
    @State private var selectedPage = 0
    @State private var pageOrder: [Int] = []
    @State private var freeTextContent = "Type here…"
    @State private var watermarkText = "CONFIDENTIAL"
    @State private var previewImages: [Int: NSImage] = [:]
    @State private var pdfTab: PDFTab = .content

    enum PDFTab: String, CaseIterable, Identifiable {
        case content = "Content"
        case pages = "Pages"
        case annotate = "Annotate"
        case screenshots = "Screenshots"
        var id: String { rawValue }
    }

    // Text
    @State private var textDocument: TextEditorService.TextDocument?
    @State private var textBody = ""
    @State private var textDirty = false

    // Image / screenshot
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
            topBar
            Divider()
            if mode == .none {
                emptyState
            } else {
                if mode == .text || mode == .pdf {
                    findReplaceBar
                    Divider()
                }
                Group {
                    switch mode {
                    case .pdf: pdfWorkspace
                    case .text: textWorkspace
                    case .image: imageWorkspace
                    case .none: EmptyView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "pencil.and.outline")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor))

            VStack(alignment: .leading, spacing: 2) {
                Text("Edit")
                    .font(.title2.weight(.bold))
                Text(mode == .none ? "Open a document and change its content — text, pages, or screenshots." : fileSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            if mode != .none {
                if isBusy { ProgressView().controlSize(.small) }
                Button("Close") { closeSession() }
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
        .padding(.vertical, 14)
        .background(.bar)
        .overlay(alignment: .bottom) {
            if !statusMessage.isEmpty || !errorMessage.isEmpty {
                HStack {
                    if !statusMessage.isEmpty {
                        Label(statusMessage, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    if !errorMessage.isEmpty {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                    Spacer()
                }
                .font(.caption)
                .padding(.horizontal, 20)
                .padding(.bottom, 6)
            }
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

    private var emptyState: some View {
        VStack(spacing: 20) {
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

            HStack(spacing: 16) {
                featureCard("Find & replace", "Change every occurrence of a word in one step", "magnifyingglass")
                featureCard("Keep layout", "Office/iWork conversions prefer Apple apps so slides don’t break", "rectangle.3.group")
                featureCard("Screenshots", "Paste or edit screenshots inside PDFs and image files", "camera.viewfinder")
            }
            .frame(maxWidth: 900)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }

    // MARK: - Find & replace bar

    private var findReplaceBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find", text: $findText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 200)
                .onChange(of: findText) { _, _ in Task { await refreshMatchCount() } }
            TextField("Replace with", text: $replaceText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 200)
            Toggle("Aa", isOn: $caseSensitive)
                .toggleStyle(.button)
                .help("Case sensitive")
                .onChange(of: caseSensitive) { _, _ in Task { await refreshMatchCount() } }

            Text(matchCount == 0 ? "No matches" : "\(matchCount) match\(matchCount == 1 ? "" : "es")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(minWidth: 80, alignment: .leading)

            Button("Replace All") { Task { await replaceAll() } }
                .buttonStyle(.borderedProminent)
                .disabled(findText.isEmpty || isBusy || matchCount == 0)
                .keyboardShortcut("r", modifiers: [.command, .option])

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
    }

    // MARK: - Text workspace

    private var textWorkspace: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let note = textDocument?.limitationNote {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle.fill")
                    Text(note)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.08))
            }
            TextEditor(text: $textBody)
                .font(.system(size: 14))
                .padding(8)
                .onChange(of: textBody) { _, _ in
                    textDirty = true
                    Task { await refreshMatchCount() }
                }
        }
    }

    // MARK: - PDF workspace

    private var pdfWorkspace: some View {
        VStack(spacing: 0) {
            Picker("", selection: $pdfTab) {
                ForEach(PDFTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(12)

            HStack(alignment: .top, spacing: 0) {
                // Page strip
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(Array(pageOrder.enumerated()), id: \.offset) { displayIndex, sourceIndex in
                            pageThumb(displayIndex: displayIndex, sourceIndex: sourceIndex)
                        }
                    }
                    .padding(10)
                }
                .frame(width: 150)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        switch pdfTab {
                        case .content:
                            pdfContentPanel
                        case .pages:
                            pdfPagesPanel
                        case .annotate:
                            pdfAnnotatePanel
                        case .screenshots:
                            pdfScreenshotPanel
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 720, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var pdfContentPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit written content")
                .font(.headline)
            Text("Use Find & Replace above to change a word everywhere it appears. This rebuilds text pages so wording stays correct; decorative layout may differ from Canva/Pages designers.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Label("Tip: For design-heavy slides, convert PPTX → PDF with Keynote first (Convert tool), then annotate here.", systemImage: "lightbulb")
                .font(.caption)
                .foregroundStyle(.secondary)

            GroupBox("Selected page") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Page \(selectedPage + 1) of \(pageOrder.count)")
                    HStack {
                        Button("Add text box") { Task { await addFreeText() } }
                        Button("Highlight band") { Task { await addHighlight() } }
                    }
                    TextField("Text box content", text: $freeTextContent)
                        .textFieldStyle(.roundedBorder)
                }
                .padding(6)
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
            Text("Paste a screenshot from the clipboard, or replace the current page with an edited image. Great for redacting UI captures inside a PDF.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
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

    private func pageThumb(displayIndex: Int, sourceIndex: Int) -> some View {
        let selected = selectedPage == displayIndex
        return VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .frame(height: 110)
                if let img = previewImages[sourceIndex] {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 100)
                } else {
                    ProgressView().controlSize(.mini)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: selected ? 2 : 1))
            Text("\(displayIndex + 1)")
                .font(.caption2)
        }
        .onTapGesture { selectedPage = displayIndex }
        .onAppear { Task { await loadPreview(sourceIndex: sourceIndex) } }
    }

    // MARK: - Image workspace

    private var imageWorkspace: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack {
                if let imageWorking {
                    Image(nsImage: imageWorking)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 520, maxHeight: 480)
                        .background(CheckerboardBackground())
                        .clipShape(RoundedRectangle(cornerRadius: 10))
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
            .padding(16)

            VStack(alignment: .leading, spacing: 14) {
                if let imageLimitation {
                    Text(imageLimitation).font(.caption).foregroundStyle(.secondary)
                }
                GroupBox("Adjust") {
                    VStack(spacing: 8) {
                        sliderRow("Brightness", $brightness, -0.5...0.5)
                        sliderRow("Contrast", $contrast, 0.5...1.5)
                        sliderRow("Saturation", $saturation, 0...2)
                    }
                    .padding(6)
                }
                GroupBox("Size & crop") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Crop 10% margins", isOn: $cropEnabled)
                        HStack {
                            TextField("W", value: $resizeWidth, format: .number).frame(width: 80)
                            Text("×")
                            TextField("H", value: $resizeHeight, format: .number).frame(width: 80)
                        }
                        Button("Apply edits") { Task { await applyImageEdits() } }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(6)
                }
                Text("Save writes back to \(imageFormat.displayName) when supported.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 280)
            .padding(.trailing, 16)
            .padding(.top, 16)
            Spacer()
        }
    }

    private func sliderRow(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title).frame(width: 80, alignment: .leading)
            Slider(value: value, in: range)
        }
    }

    // MARK: - Open / save

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
                // Guide user: convert with fidelity first, then edit PDF
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

    // MARK: - Find / replace

    private func refreshMatchCount() async {
        guard !findText.isEmpty else { matchCount = 0; return }
        switch mode {
        case .text:
            matchCount = await app.textEditor.countMatches(
                text: textBody, search: findText, caseSensitive: caseSensitive
            )
        case .pdf:
            guard let id = pdfSessionID else { matchCount = 0; return }
            do {
                matchCount = try await app.pdfEditor.countTextMatches(
                    id: id, search: findText, caseSensitive: caseSensitive
                )
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
                statusMessage = result.replacedCount == 0
                    ? "No matches."
                    : "Replaced \(result.replacedCount) occurrence(s)."
            case .pdf:
                guard let id = pdfSessionID else { return }
                let result = try await app.pdfEditor.replaceAllText(
                    id: id, search: findText, replace: replaceText, caseSensitive: caseSensitive
                )
                matchCount = 0
                statusMessage = result.notes.joined(separator: " ")
                await refreshPDFSnapshot()
            default:
                break
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - PDF actions (same as before, condensed)

    private func refreshPDFSnapshot() async {
        guard let id = pdfSessionID else { return }
        do {
            let snap = try await app.pdfEditor.snapshot(id: id)
            pdfSnapshot = snap
            pageOrder = Array(0..<snap.pageCount)
            previewImages = [:]
            if selectedPage >= snap.pageCount { selectedPage = max(0, snap.pageCount - 1) }
            for i in pageOrder.prefix(12) { await loadPreview(sourceIndex: i) }
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
            statusMessage = "Exported page PNG — open in Edit as an image, then Replace page with clipboard."
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

    // MARK: - Image actions

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

/// Subtle checkerboard behind transparent images.
private struct CheckerboardBackground: View {
    var body: some View {
        Canvas { context, size in
            let s: CGFloat = 10
            var y: CGFloat = 0
            var row = 0
            while y < size.height {
                var x: CGFloat = 0
                var col = 0
                while x < size.width {
                    let light = (row + col) % 2 == 0
                    context.fill(
                        Path(CGRect(x: x, y: y, width: s, height: s)),
                        with: .color(light ? Color.gray.opacity(0.15) : Color.gray.opacity(0.28))
                    )
                    x += s; col += 1
                }
                y += s; row += 1
            }
        }
    }
}
