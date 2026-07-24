import SwiftUI
import AppKit
import UniformTypeIdentifiers
import DocuForgeCore

/// Full WYSIWYG editor chrome — canvas center, inspector for selection, AI panel.
struct DocumentEditorWorkspace: View {
    @ObservedObject var session: DocumentEditorSession
    @Binding var statusMessage: String
    var onSave: () -> Void
    var onSaveAs: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            buildBanner
            toolbar
            findBar
            Divider()
            HStack(spacing: 0) {
                pageRail
                Divider()
                DocumentCanvasView(session: session)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                inspector
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if session.showAIPanel || session.aiPlan != nil {
                aiPanel
            }
            footer
        }
        .onChange(of: session.status) { _, n in statusMessage = n }
        .focusable()
        .onKeyPress(.delete) {
            session.deleteSelection()
            return .handled
        }
        .onKeyPress(.escape) {
            if session.editingTextID != nil {
                if let id = session.editingTextID {
                    // commit via ending without text — user should use Done
                    session.commitOpenTextEdit()
                } else {
                    session.select(id: nil)
                }
            } else {
                session.select(id: nil)
            }
            return .handled
        }
    }

    private var buildBanner: some View {
        HStack {
            Text(DocumentEditorSession.buildLabel)
                .font(.caption2.weight(.semibold))
            Text("· WYSIWYG canvas editor (document model)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            Text("Double-click text to edit · Drag to move · ⌘Z undo")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color.accentColor.opacity(0.10))
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            ForEach(DocumentEditorSession.Tool.allCases) { tool in
                Button {
                    session.tool = tool
                } label: {
                    Label(tool.title, systemImage: tool.systemImage)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(session.tool == tool ? Color.accentColor.opacity(0.22) : Color(nsColor: .controlBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(session.tool == tool ? Color.accentColor : Color.primary.opacity(0.1))
                        )
                }
                .buttonStyle(.plain)
                .help(toolHelp(tool))
            }

            Divider().frame(height: 22)

            Button { session.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!session.canUndo)
                .help("Undo ⌘Z")
            Button { session.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!session.canRedo)
                .help("Redo")

            Button {
                session.setZoom(session.zoom - 0.1)
            } label: { Image(systemName: "minus.magnifyingglass") }
            Text("\(Int(session.zoom * 100))%")
                .font(.caption.monospacedDigit())
                .frame(width: 44)
            Button {
                session.setZoom(session.zoom + 0.1)
            } label: { Image(systemName: "plus.magnifyingglass") }

            Button {
                session.insertBlankPage()
            } label: { Label("Page", systemImage: "doc.badge.plus") }

            Button {
                insertImage()
            } label: { Label("Image…", systemImage: "photo.badge.plus") }

            if session.editingTextID != nil {
                Button("Done editing") {
                    // Text commit is handled by binding — force end
                    session.commitOpenTextEdit()
                    statusMessage = "Finished text edit. Use style inspector while selected to change font."
                }
                .buttonStyle(.borderedProminent)
            }

            Spacer()

            Button {
                session.showAIPanel.toggle()
            } label: {
                Label("AI Assistant", systemImage: "sparkles")
            }

            Button("Close", action: onClose)
            Button("Save As…", action: onSaveAs)
            Button("Save", action: onSave)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s", modifiers: .command)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var findBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
            TextField("Find in document", text: $session.findQuery)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 160)
            TextField("Replace with", text: $session.replaceQuery)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 160)
            Toggle("Aa", isOn: $session.caseSensitive).toggleStyle(.button)
            Button("Replace All") {
                session.replaceAll()
                statusMessage = session.status
            }
            .buttonStyle(.borderedProminent)
            .disabled(session.findQuery.isEmpty)
            Spacer()
            Text("Editing the document model — not OCR paint-over.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var pageRail: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(0..<session.pageCount, id: \.self) { i in
                    Button {
                        session.goToPage(i)
                    } label: {
                        VStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.white)
                                .frame(width: 48, height: 64)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .strokeBorder(
                                            session.currentPageIndex == i ? Color.accentColor : Color.primary.opacity(0.15),
                                            lineWidth: session.currentPageIndex == i ? 2 : 1
                                        )
                                )
                                .shadow(radius: 1)
                            Text("\(i + 1)")
                                .font(.caption2)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
        }
        .frame(width: 72)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Inspector")
                .font(.headline)
            if let obj = session.primarySelection {
                Text(obj.name.isEmpty ? obj.id.uuidString.prefix(8) + "…" : obj.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(kindLabel(obj))
                    .font(.caption2)
                    .padding(4)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                if case .text(let t) = obj.kind {
                    Text("Text style").font(.subheadline.weight(.semibold))
                    HStack {
                        Text("Size")
                        Slider(
                            value: Binding(
                                get: { t.style.fontSize },
                                set: { new in
                                    session.updatePrimaryTextStyle { $0.fontSize = new }
                                }
                            ),
                            in: 8...72
                        )
                        Text("\(Int(t.style.fontSize))")
                            .font(.caption.monospacedDigit())
                    }
                    Toggle("Bold", isOn: Binding(
                        get: { t.style.bold },
                        set: { new in session.updatePrimaryTextStyle { $0.bold = new } }
                    ))
                    HStack {
                        Button("Black") { session.updatePrimaryTextStyle { $0.color = .black } }
                        Button("Blue") { session.updatePrimaryTextStyle { $0.color = .blue } }
                        Button("Red") { session.updatePrimaryTextStyle { $0.color = .red } }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Button("Edit on canvas") {
                        session.beginTextEdit(obj.id)
                    }
                    .buttonStyle(.borderedProminent)
                }

                if case .table = obj.kind {
                    Text("Table selected. Double-click cells in a future build; for now edit via AI or recreate.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Divider()
                HStack {
                    Button("Bring forward") {
                        // simple z bump
                        session.beginGesture()
                        _ = session.scene // force
                    }
                    .disabled(true)
                    .help("Coming next")
                    Button(role: .destructive) {
                        session.deleteSelection()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            } else {
                Text("Select an object on the page to edit its properties.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Tips")
                    .font(.subheadline.weight(.semibold))
                    .padding(.top, 8)
                tip("Double-click text", "Edit in place on the canvas")
                tip("Drag", "Move selected objects")
                tip("Corner handle", "Resize selection")
                tip("AI Assistant", "Natural language edits with preview")
            }
            Spacer()
        }
        .padding(12)
        .frame(width: 260)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }

    private var aiPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("AI Assistant", systemImage: "sparkles")
                    .font(.headline)
                Spacer()
                Button("Close") {
                    session.showAIPanel = false
                    session.dismissAIPlan()
                }
            }
            Text("Instructions apply to the document model (text objects, styles). Review a preview before applying. Full undo supported.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                TextField("e.g. replace Summer with Winter, change all headings to blue", text: $session.aiInstruction)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { session.runAI() }
                Button("Plan") {
                    session.runAI()
                }
                .buttonStyle(.borderedProminent)
                .disabled(session.aiInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.aiBusy)
            }
            if let plan = session.aiPlan {
                VStack(alignment: .leading, spacing: 6) {
                    Text(plan.title).font(.subheadline.weight(.semibold))
                    Text(plan.summary).font(.caption).foregroundStyle(.secondary)
                    Text("\(plan.operations.count) operation(s)")
                        .font(.caption2)
                    HStack {
                        Button("Apply to document") {
                            session.applyAIPlan()
                            statusMessage = session.status
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Discard") {
                            session.dismissAIPlan()
                        }
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var footer: some View {
        HStack {
            Text(session.status)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            if session.isDirty {
                Text("Unsaved changes")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            Text("Page \(session.currentPageIndex + 1)/\(session.pageCount)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func tip(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.weight(.semibold))
            Text(body).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func kindLabel(_ obj: CanvasObject) -> String {
        switch obj.kind {
        case .text: return "Text"
        case .image: return "Image"
        case .shape: return "Shape"
        case .table: return "Table"
        }
    }

    private func toolHelp(_ tool: DocumentEditorSession.Tool) -> String {
        switch tool {
        case .select: return "Select and move objects"
        case .text: return "Click on the page to add a text box"
        case .shape: return "Click to add a rectangle"
        case .table: return "Click to add a table"
        case .image: return "Use Image… to insert"
        }
    }

    private func insertImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic, .gif]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            session.insertImage(url: url)
            statusMessage = session.status
        }
    }
}
