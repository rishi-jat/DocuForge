import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PDFKit
import DocuForgeCore

/// Document editor: open a PDF (or convert to PDF) and edit on the page —
/// like Pages / iLovePDF / Canva for documents, with find-replace and screenshot tools.
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
    @State private var matchCount = 0

    // Image mode
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

    // Page image sheet
    @State private var sheetImage: NSImage?
    @State private var sheetBrightness: Double = 0
    @State private var sheetContrast: Double = 1
    @State private var sheetSaturation: Double = 1

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
                case .pdf: pdfCanvasWorkspace
                case .text: textWorkspace
                case .image: imageWorkspace
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
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Label(modeTitle, systemImage: modeIcon)
                .font(.headline)
                .labelStyle(.titleAndIcon)

            if let name = sourceURL?.lastPathComponent {
                Text(name)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if mode == .pdf, let session = pdfSessionHolder.session {
                // Canvas tools
                Picker("Tool", selection: Binding(
                    get: { session.tool },
                    set: { session.tool = $0 }
                )) {
                    ForEach(LivePDFSession.Tool.allCases) { tool in
                        Label(tool.title, systemImage: tool.systemImage).tag(tool)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 420)

                Button {
                    session.rotateCurrentPage(90)
                    statusMessage = session.status
                } label: {
                    Image(systemName: "rotate.right")
                }
                .help("Rotate page")

                Button(role: .destructive) {
                    session.deleteCurrentPage()
                    statusMessage = session.status
                } label: {
                    Image(systemName: "trash")
                }
                .help("Delete page")
            }

            if mode != .none {
                Button("Close") { closeSession() }
                Button("Save As…") { Task { await saveAs() } }
                Button("Save") {
                    Task { await save() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(mode == .none || isBusy)
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
        case .image: return "Image Editor"
        }
    }

    private var modeIcon: String {
        switch mode {
        case .none: return "pencil.and.outline"
        case .pdf: return "doc.richtext"
        case .text: return "doc.plaintext"
        case .image: return "photo"
        }
    }

    private var canSave: Bool {
        switch mode {
        case .pdf: return pdfSessionHolder.session?.isDirty == true
        case .text: return textDirty
        case .image: return imageDirty
        case .none: return false
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
                title: "Open a document to edit",
                subtitle: "PDFs open on a live canvas. Word/text files open in the text editor. Images open for screenshot-style edits. Office/iWork: convert to PDF first for layout-safe visual editing.",
                systemImage: "doc.badge.plus",
                allowedTypes: [.item],
                allowsMultiple: false
            ) { urls in
                if let url = urls.first { Task { await open(url) } }
            }
            .frame(maxWidth: 640)

            HStack(spacing: 16) {
                tip("Live PDF canvas", "Click the page to add text, highlights, or signatures — like iLovePDF / Pages.")
                tip("Replace all", "Find a word and replace every match without rebuilding the whole design.")
                tip("Screenshots", "Edit a page as an image or paste a screenshot; the file stays PDF.")
            }
            .frame(maxWidth: 900)
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

    // MARK: - PDF canvas workspace (main product experience)

    private var pdfCanvasWorkspace: some View {
        VStack(spacing: 0) {
            // Find & replace bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                TextField("Find in document", text: Binding(
                    get: { pdfSessionHolder.session?.findQuery ?? "" },
                    set: { pdfSessionHolder.session?.findQuery = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 180)

                TextField("Replace with", text: Binding(
                    get: { pdfSessionHolder.session?.replaceQuery ?? "" },
                    set: { pdfSessionHolder.session?.replaceQuery = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 180)

                Toggle("Aa", isOn: Binding(
                    get: { pdfSessionHolder.session?.caseSensitive ?? false },
                    set: { pdfSessionHolder.session?.caseSensitive = $0 }
                ))
                .toggleStyle(.button)
                .help("Case sensitive")

                Button("Find") {
                    pdfSessionHolder.session?.refreshFind()
                    statusMessage = pdfSessionHolder.session?.status ?? ""
                }
                Button("Next") {
                    // next needs pdf view reference — use session page only
                    if let s = pdfSessionHolder.session, !s.findHits.isEmpty {
                        s.findIndex = (s.findIndex + 1) % s.findHits.count
                        let hit = s.findHits[s.findIndex]
                        s.currentPageIndex = hit.page
                        statusMessage = "Match \(s.findIndex + 1) of \(s.findHits.count)"
                    }
                }
                Button("Replace All") {
                    pdfSessionHolder.session?.replaceAllPreservingLayout()
                    statusMessage = pdfSessionHolder.session?.status ?? ""
                }
                .buttonStyle(.borderedProminent)
                .disabled((pdfSessionHolder.session?.findQuery ?? "").isEmpty)

                if let n = pdfSessionHolder.session?.matchCount, n > 0 {
                    Text("\(n) matches").font(.caption).foregroundStyle(.secondary)
                }

                Spacer()

                // Screenshot actions always visible
                Button {
                    pdfSessionHolder.session?.pasteScreenshotReplacingPage()
                    statusMessage = pdfSessionHolder.session?.status ?? ""
                } label: {
                    Label("Paste screenshot on page", systemImage: "doc.on.clipboard")
                }
                Button {
                    pdfSessionHolder.session?.beginEditPageAsImage()
                    sheetImage = pdfSessionHolder.session?.pageImageForEdit
                    sheetBrightness = 0; sheetContrast = 1; sheetSaturation = 1
                } label: {
                    Label("Edit page image", systemImage: "photo.on.rectangle")
                }
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.9))

            // Tool hint + text draft
            if let session = pdfSessionHolder.session {
                HStack(spacing: 12) {
                    Text(toolHint(session.tool))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if session.tool == .text {
                        TextField("Text to place", text: Binding(
                            get: { session.textBoxDraft },
                            set: { session.textBoxDraft = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }

            HStack(spacing: 0) {
                // Page thumbnails
                if let session = pdfSessionHolder.session {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(0..<session.pageCount, id: \.self) { i in
                                Button {
                                    session.goToPage(i)
                                } label: {
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

                    Divider()

                    // LIVE CANVAS
                    PDFCanvasView(session: session)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Footer note
            Text("Edits are annotations or page-image replacements on the original PDF pages — the file stays PDF and unedited pages keep their original look.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(8)
        }
    }

    private func toolHint(_ tool: LivePDFSession.Tool) -> String {
        switch tool {
        case .select: return "Select: drag to select text in the PDF (for reading). Switch tool to edit."
        case .text: return "Text: click on the page to place a text box. Edit draft text in the field below tools if needed."
        case .highlight: return "Highlight: click on the page to stamp a highlight band."
        case .signature: return "Sign: click where the signature should appear."
        case .screenshot: return "Screenshot: click a page to open it as an image for crop/adjust, or use Paste screenshot."
        }
    }

    // MARK: - Page image editor sheet

    private var pageImageEditorSheet: some View {
        VStack(spacing: 16) {
            Text("Edit page as image")
                .font(.title2.weight(.bold))
            Text("Adjust this page’s screenshot. Applying replaces only this page; other pages and the PDF format stay the same.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let base = pdfSessionHolder.session?.pageImageForEdit {
                let preview = sheetPreview(from: base)
                if let preview {
                    Image(nsImage: preview)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 420)
                        .border(Color.primary.opacity(0.15))
                }
            }

            HStack {
                Text("Brightness"); Slider(value: $sheetBrightness, in: -0.4...0.4)
            }
            HStack {
                Text("Contrast"); Slider(value: $sheetContrast, in: 0.6...1.5)
            }
            HStack {
                Text("Saturation"); Slider(value: $sheetSaturation, in: 0...2)
            }

            HStack {
                Button("Cancel") {
                    pdfSessionHolder.session?.showPageImageEditor = false
                }
                Spacer()
                Button("Paste clipboard instead") {
                    pdfSessionHolder.session?.pasteScreenshotReplacingPage()
                    statusMessage = pdfSessionHolder.session?.status ?? ""
                }
                Button("Apply to page") {
                    Task { await applySheetImage() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(minWidth: 640, minHeight: 560)
    }

    private func sheetPreview(from base: NSImage) -> NSImage? {
        // Quick preview using Core Image-ish path via ImageEditor — sync approximate by redraw
        // For sheet we apply on Apply only; preview uses simple filter if possible
        return base
    }

    private func applySheetImage() async {
        guard let session = pdfSessionHolder.session,
              let base = session.pageImageForEdit else { return }
        do {
            let edited = try await app.imageEditor.apply(
                image: base,
                cropNormalized: nil,
                targetSize: nil,
                adjustments: .init(brightness: sheetBrightness, contrast: sheetContrast, saturation: sheetSaturation)
            )
            session.applyEditedPageImage(edited)
            statusMessage = session.status
        } catch {
            errorMessage = error.localizedDescription
        }
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
                        matchCount = r.replacedCount
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

    // MARK: - Image workspace

    private var imageWorkspace: some View {
        HStack(alignment: .top, spacing: 20) {
            if let imageWorking {
                Image(nsImage: imageWorking)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 520, maxHeight: 480)
                    .padding(12)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("Screenshot / image tools").font(.headline)
                Button {
                    if let img = NSImage(pasteboard: .general) {
                        imageOriginal = img; imageWorking = img; imageDirty = true
                        imageFormat = .png
                        statusMessage = "Pasted screenshot."
                    } else {
                        errorMessage = "Clipboard has no image."
                    }
                } label: {
                    Label("Paste screenshot", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.borderedProminent)

                HStack { Text("Brightness"); Slider(value: $brightness, in: -0.5...0.5) }
                HStack { Text("Contrast"); Slider(value: $contrast, in: 0.5...1.5) }
                HStack { Text("Saturation"); Slider(value: $saturation, in: 0...2) }
                Toggle("Crop 10% margins", isOn: $cropEnabled)
                HStack {
                    TextField("W", value: $resizeWidth, format: .number).frame(width: 70).textFieldStyle(.roundedBorder)
                    Text("×")
                    TextField("H", value: $resizeHeight, format: .number).frame(width: 70).textFieldStyle(.roundedBorder)
                }
                Button("Apply") { Task { await applyImageEdits() } }
                    .buttonStyle(.borderedProminent)
                Button("Reset") {
                    imageWorking = imageOriginal
                    brightness = 0; contrast = 1; saturation = 1; cropEnabled = false
                    imageDirty = false
                }
            }
            .frame(width: 280)
            Spacer()
        }
        .padding(20)
    }

    // MARK: - Open / save

    private func open(_ url: URL) async {
        errorMessage = ""; statusMessage = ""; isBusy = true
        defer { isBusy = false }
        let format = DocumentFormat.detect(url: url)
        do {
            if format == .pdf {
                let session = try LivePDFSession.open(url: url)
                pdfSessionHolder.session = session
                sourceURL = url
                mode = .pdf
                statusMessage = "PDF opened on canvas. Choose a tool, then click the page. Format stays PDF."
            } else if format.isImage {
                let img = try await app.imageEditor.load(url: url)
                imageOriginal = img
                imageWorking = img
                imageFormat = format
                resizeWidth = Double(img.size.width)
                resizeHeight = Double(img.size.height)
                sourceURL = url
                mode = .image
                statusMessage = "Image opened."
            } else if await app.textEditor.isEditableTextFormat(format) {
                let doc = try await app.textEditor.open(url: url)
                textDocument = doc
                textBody = doc.text
                textDirty = false
                sourceURL = url
                mode = .text
                statusMessage = "Text document opened. Use Find / Replace All for wording."
            } else if format.isIWork || format.isOfficeOpenXML || format.isLegacyOffice || format.isOpenDocument {
                // Convert to PDF first for canvas editing (layout-safe path)
                statusMessage = "Preparing a layout-safe PDF for visual editing…"
                let dir = try app.makeOutputDirectory(named: "EditOpen")
                let result = try await app.conversion.convert(url: url, to: .pdf, outputDirectory: dir)
                guard let pdfURL = result.outputURLs.first else {
                    throw DocuForgeError.conversionFailed("Could not create PDF for editing.")
                }
                let session = try LivePDFSession.open(url: pdfURL)
                pdfSessionHolder.session = session
                sourceURL = pdfURL
                mode = .pdf
                let notes = result.notes.joined(separator: " ")
                statusMessage = "Opened \(format.displayName) as PDF for on-canvas editing (keeps a stable visual format). \(notes)"
            } else {
                errorMessage = "Can’t open \(format.displayName) for editing. Convert to PDF first."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func closeSession() {
        pdfSessionHolder.session = nil
        textDocument = nil; textBody = ""; textDirty = false
        imageOriginal = nil; imageWorking = nil; imageDirty = false
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
                statusMessage = "Saved image."
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

    private func applyImageEdits() async {
        guard let original = imageOriginal else { return }
        do {
            let crop: CGRect? = cropEnabled ? CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8) : nil
            let size: CGSize? = (resizeWidth > 0 && resizeHeight > 0) ? CGSize(width: resizeWidth, height: resizeHeight) : nil
            imageWorking = try await app.imageEditor.apply(
                image: original,
                cropNormalized: crop,
                targetSize: size,
                adjustments: .init(brightness: brightness, contrast: contrast, saturation: saturation)
            )
            imageDirty = true
            statusMessage = "Applied image edits."
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Holds optional LivePDFSession for @StateObject compatibility.
@MainActor
final class PDFSessionHolder: ObservableObject {
    @Published var session: LivePDFSession?
}
