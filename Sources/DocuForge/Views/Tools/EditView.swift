import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PDFKit
import DocuForgeCore

/// Document editor: open a PDF (or convert to PDF) and edit on the page —
/// click existing words like Canva / iLovePDF, find-replace, screenshots.
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
    @State private var sheetCrop: Bool = false
    @State private var sheetPreview: NSImage?

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
                Button {
                    session.rotateCurrentPage(90)
                    statusMessage = session.status
                } label: {
                    Image(systemName: "rotate.right")
                }
                .help("Rotate page")

                Button {
                    session.insertBlankPage()
                    statusMessage = session.status
                } label: {
                    Image(systemName: "doc.badge.plus")
                }
                .help("Insert blank page")

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
                subtitle: "PDFs open on a live canvas — click a word to change it (like Canva / iLovePDF). Images open for screenshot edits. Office/iWork convert to PDF for layout-safe editing.",
                systemImage: "doc.badge.plus",
                allowedTypes: [.item],
                allowsMultiple: false
            ) { urls in
                if let url = urls.first { Task { await open(url) } }
            }
            .frame(maxWidth: 640)

            HStack(spacing: 16) {
                tip("Click to edit words", "Use Edit word → click any word on the page → change it → Apply. The rest of the layout stays.")
                tip("Find & replace all", "Change every match across pages without rebuilding the PDF design.")
                tip("Screenshots stay PDF", "Edit a page as an image or paste ⌘⇧4 screenshots — the file remains PDF.")
            }
            .frame(maxWidth: 960)
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

    // MARK: - PDF canvas workspace

    private var pdfCanvasWorkspace: some View {
        VStack(spacing: 0) {
            findReplaceBar
            toolStrip
            if pdfSessionHolder.session?.selectedHit != nil {
                selectedTextEditorBar
            }
            HStack(spacing: 0) {
                pageThumbs
                Divider()
                if let session = pdfSessionHolder.session {
                    PDFCanvasView(session: session)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Text("Tip: select “Edit word”, click the text on the page, type the new word, press Apply. Screenshots: use Screenshot tool or Paste — document stays PDF.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(8)
        }
    }

    private var findReplaceBar: some View {
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

            Button {
                pdfSessionHolder.session?.pasteScreenshotReplacingPage()
                statusMessage = pdfSessionHolder.session?.status ?? ""
            } label: {
                Label("Paste screenshot", systemImage: "doc.on.clipboard")
            }
            .help("Replace current page with clipboard image (⌘⇧4). Stays PDF.")

            Button {
                pdfSessionHolder.session?.pasteScreenshotAsNewPage()
                statusMessage = pdfSessionHolder.session?.status ?? ""
            } label: {
                Label("Insert shot", systemImage: "plus.rectangle.on.rectangle")
            }
            .help("Insert clipboard image as a new PDF page.")

            Button {
                openScreenshotEditor()
            } label: {
                Label("Edit page image", systemImage: "photo.on.rectangle")
            }
            .help("Open current page as a screenshot for brightness/crop, then apply back to the PDF page.")
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.9))
    }

    private var toolStrip: some View {
        Group {
            if let session = pdfSessionHolder.session {
                VStack(alignment: .leading, spacing: 6) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(LivePDFSession.Tool.allCases) { tool in
                                Button {
                                    session.tool = tool
                                    if tool != .editText {
                                        // keep selection if still editing, but clear flash noise for other tools
                                    }
                                } label: {
                                    Label(tool.title, systemImage: tool.systemImage)
                                        .labelStyle(.titleAndIcon)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(
                                            RoundedRectangle(cornerRadius: 8)
                                                .fill(session.tool == tool ? Color.accentColor.opacity(0.22) : Color(nsColor: .controlBackgroundColor))
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .strokeBorder(session.tool == tool ? Color.accentColor : Color.primary.opacity(0.12))
                                        )
                                }
                                .buttonStyle(.plain)
                                .help(toolHint(tool))
                            }
                        }
                    }

                    HStack(spacing: 12) {
                        Text(toolHint(session.tool))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if session.tool == .editText {
                            Picker("Pick", selection: Binding(
                                get: { session.textPickMode },
                                set: { session.textPickMode = $0 }
                            )) {
                                ForEach(LivePDFSession.TextPickMode.allCases) { m in
                                    Text(m.title).tag(m)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 140)
                            .help("Click selects a single word, or the whole line.")
                        }

                        if session.tool == .addText {
                            TextField("Text to place", text: Binding(
                                get: { session.textBoxDraft },
                                set: { session.textBoxDraft = $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                        }

                        if session.tool == .stamp {
                            TextField("Stamp text", text: Binding(
                                get: { session.stampDraft },
                                set: { session.stampDraft = $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 140)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
    }

    /// Panel that appears after clicking existing PDF text — change the word and Apply.
    private var selectedTextEditorBar: some View {
        Group {
            if let session = pdfSessionHolder.session, let hit = session.selectedHit {
                HStack(spacing: 12) {
                    Image(systemName: "character.cursor.ibeam")
                        .foregroundStyle(Color.accentColor)
                        .font(.title3)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Edit existing text on page \(hit.pageIndex + 1)")
                            .font(.caption.weight(.semibold))
                        Text("Original: “\(hit.originalText)”")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .frame(minWidth: 160, maxWidth: 280, alignment: .leading)

                    TextField("New text", text: Binding(
                        get: { session.editDraft },
                        set: { session.editDraft = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 180, maxWidth: 360)
                    .onSubmit {
                        session.applySelectedTextEdit()
                        statusMessage = session.status
                    }

                    Button("Apply change") {
                        session.applySelectedTextEdit()
                        statusMessage = session.status
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)

                    Button("Erase") {
                        session.eraseSelectedText()
                        statusMessage = session.status
                    }
                    .help("Cover the selected text with white (layout kept).")

                    Button("Cancel") {
                        session.clearTextSelection()
                        statusMessage = "Selection cleared."
                    }

                    Spacer()
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 0)
                        .fill(Color.accentColor.opacity(0.10))
                )
                .overlay(alignment: .top) {
                    Rectangle().fill(Color.accentColor).frame(height: 2)
                }
            }
        }
    }

    private var pageThumbs: some View {
        Group {
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
            }
        }
    }

    private func toolHint(_ tool: LivePDFSession.Tool) -> String {
        switch tool {
        case .select:
            return "Select: drag to highlight text for reading/copy. Switch to Edit word to change text."
        case .editText:
            return "Edit word: CLICK an existing word on the page → it appears below → type new text → Apply. Like Canva / iLovePDF."
        case .addText:
            return "Add text: click empty space to place a new text box (does not change existing words)."
        case .highlight:
            return "Highlight: click a word to highlight it."
        case .underline:
            return "Underline: click a word to underline it."
        case .strike:
            return "Strike: click a word to strike it through."
        case .signature:
            return "Sign: click where the signature should appear."
        case .stamp:
            return "Stamp: click to place APPROVED / custom stamp."
        case .screenshot:
            return "Screenshot: click the page to open brightness/crop editor, or use Paste screenshot. File stays PDF."
        }
    }

    private func openScreenshotEditor() {
        pdfSessionHolder.session?.beginEditPageAsImage()
        sheetImage = pdfSessionHolder.session?.pageImageForEdit
        sheetBrightness = 0
        sheetContrast = 1
        sheetSaturation = 1
        sheetCrop = false
        sheetPreview = sheetImage
        Task { await refreshSheetPreview() }
    }

    // MARK: - Page image editor sheet (screenshots)

    private var pageImageEditorSheet: some View {
        VStack(spacing: 16) {
            Text("Edit page as screenshot")
                .font(.title2.weight(.bold))
            Text("Adjust this page’s image. Applying replaces only this page; other pages stay original PDF. The document format remains PDF.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)

            Group {
                if let preview = sheetPreview ?? sheetImage ?? pdfSessionHolder.session?.pageImageForEdit {
                    Image(nsImage: preview)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 380)
                        .padding(8)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
                } else {
                    Text("No page image loaded.")
                        .foregroundStyle(.secondary)
                        .frame(height: 200)
                }
            }

            VStack(spacing: 10) {
                HStack { Text("Brightness").frame(width: 90, alignment: .leading); Slider(value: $sheetBrightness, in: -0.4...0.4) }
                HStack { Text("Contrast").frame(width: 90, alignment: .leading); Slider(value: $sheetContrast, in: 0.6...1.5) }
                HStack { Text("Saturation").frame(width: 90, alignment: .leading); Slider(value: $sheetSaturation, in: 0...2) }
                Toggle("Crop 8% margins", isOn: $sheetCrop)
            }
            .onChange(of: sheetBrightness) { _, _ in Task { await refreshSheetPreview() } }
            .onChange(of: sheetContrast) { _, _ in Task { await refreshSheetPreview() } }
            .onChange(of: sheetSaturation) { _, _ in Task { await refreshSheetPreview() } }
            .onChange(of: sheetCrop) { _, _ in Task { await refreshSheetPreview() } }

            HStack {
                Button("Cancel") {
                    pdfSessionHolder.session?.showPageImageEditor = false
                }
                Spacer()
                Button("Paste clipboard instead") {
                    pdfSessionHolder.session?.pasteScreenshotReplacingPage()
                    statusMessage = pdfSessionHolder.session?.status ?? ""
                }
                Button("Apply to this PDF page") {
                    Task { await applySheetImage() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(minWidth: 680, minHeight: 640)
        .onAppear {
            sheetImage = pdfSessionHolder.session?.pageImageForEdit
            sheetPreview = sheetImage
            Task { await refreshSheetPreview() }
        }
    }

    private func refreshSheetPreview() async {
        guard let base = sheetImage ?? pdfSessionHolder.session?.pageImageForEdit else { return }
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
                Text("Yes — you can edit screenshots here. Paste from clipboard (⌘⇧4 → copy), adjust, save as PNG/JPEG.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    if let img = NSImage(pasteboard: .general) {
                        imageOriginal = img; imageWorking = img; imageDirty = true
                        imageFormat = .png
                        statusMessage = "Pasted screenshot."
                    } else {
                        errorMessage = "Clipboard has no image. Capture with ⌘⇧4 first."
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
                session.tool = .editText
                pdfSessionHolder.session = session
                sourceURL = url
                mode = .pdf
                statusMessage = "PDF on canvas. Tool is “Edit word”: click a word, change it, press Apply. Format stays PDF."
            } else if format.isImage {
                let img = try await app.imageEditor.load(url: url)
                imageOriginal = img
                imageWorking = img
                imageFormat = format
                resizeWidth = Double(img.size.width)
                resizeHeight = Double(img.size.height)
                sourceURL = url
                mode = .image
                statusMessage = "Image / screenshot opened. Adjust and Save."
            } else if await app.textEditor.isEditableTextFormat(format) {
                let doc = try await app.textEditor.open(url: url)
                textDocument = doc
                textBody = doc.text
                textDirty = false
                sourceURL = url
                mode = .text
                statusMessage = "Text document opened. Use Find / Replace All for wording."
            } else if format.isIWork || format.isOfficeOpenXML || format.isLegacyOffice || format.isOpenDocument {
                statusMessage = "Preparing a layout-safe PDF for visual editing…"
                let dir = try app.makeOutputDirectory(named: "EditOpen")
                let result = try await app.conversion.convert(url: url, to: .pdf, outputDirectory: dir)
                guard let pdfURL = result.outputURLs.first else {
                    throw DocuForgeError.conversionFailed("Could not create PDF for editing.")
                }
                let session = try LivePDFSession.open(url: pdfURL)
                session.tool = .editText
                pdfSessionHolder.session = session
                sourceURL = pdfURL
                mode = .pdf
                let notes = result.notes.joined(separator: " ")
                statusMessage = "Opened \(format.displayName) as PDF for canvas editing. Click words with Edit word. \(notes)"
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
