import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import DocuForgeCore

/// Live WYSIWYG session — document scene is the source of truth.
@MainActor
final class DocumentEditorSession: ObservableObject {
    static let buildLabel = "DocuForge Canvas 2026.7.25"

    enum Tool: String, CaseIterable, Identifiable {
        case select, text, shape, table, image
        var id: String { rawValue }
        var title: String {
            switch self {
            case .select: return "Select"
            case .text: return "Text"
            case .shape: return "Shape"
            case .table: return "Table"
            case .image: return "Image"
            }
        }
        var systemImage: String {
            switch self {
            case .select: return "cursorarrow"
            case .text: return "textformat"
            case .shape: return "rectangle"
            case .table: return "tablecells"
            case .image: return "photo"
            }
        }
    }

    @Published private(set) var scene: DocumentScene
    @Published var currentPageIndex: Int = 0
    @Published var selection: Set<UUID> = []
    @Published var tool: Tool = .select
    @Published var zoom: CGFloat = 1.0
    @Published var isDirty: Bool = false
    @Published var status: String = ""
    @Published var editingTextID: UUID?
    @Published var textEditDraft: String = ""
    @Published var findQuery: String = ""
    @Published var replaceQuery: String = ""
    @Published var caseSensitive: Bool = false

    // AI
    @Published var aiInstruction: String = ""
    @Published var aiPlan: AIDocumentAssistant.Plan?
    @Published var showAIPanel: Bool = false
    @Published var aiBusy: Bool = false

    private(set) public var sourceURL: URL?
    private var history = DocumentHistory()
    private let assistant = AIDocumentAssistant()

    var pageCount: Int { scene.pageCount }
    var currentPage: DocPage? { scene.page(at: currentPageIndex) }
    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }
    var selectedObjects: [CanvasObject] {
        guard let page = currentPage else { return [] }
        return page.objects.filter { selection.contains($0.id) }
    }
    var primarySelection: CanvasObject? { selectedObjects.first }

    init(scene: DocumentScene, sourceURL: URL? = nil) {
        self.scene = scene
        self.sourceURL = sourceURL
        self.status = "\(Self.buildLabel) — click to select, double-click text to edit on the page."
    }

    static func open(url: URL) throws -> DocumentEditorSession {
        let scene = try DocumentImporter.open(url: url)
        return DocumentEditorSession(scene: scene, sourceURL: url)
    }

    static func blank() -> DocumentEditorSession {
        DocumentEditorSession(scene: DocumentImporter.blankDocument())
    }

    // MARK: - History

    private func checkpoint() {
        history.push(scene)
    }

    func undo() {
        guard let previous = history.undo(current: scene) else { return }
        scene = previous
        isDirty = true
        status = "Undo"
        objectWillChange.send()
    }

    func redo() {
        guard let next = history.redo(current: scene) else { return }
        scene = next
        isDirty = true
        status = "Redo"
        objectWillChange.send()
    }

    // MARK: - Navigation

    func goToPage(_ index: Int) {
        guard scene.pages.indices.contains(index) else { return }
        currentPageIndex = index
        selection = []
        editingTextID = nil
    }

    func setZoom(_ z: CGFloat) {
        zoom = min(4, max(0.25, z))
    }

    // MARK: - Selection

    func select(id: UUID?, additive: Bool = false) {
        guard let id else {
            selection = []
            editingTextID = nil
            return
        }
        if additive {
            if selection.contains(id) { selection.remove(id) }
            else { selection.insert(id) }
        } else {
            selection = [id]
        }
        if editingTextID != nil, editingTextID != id {
            editingTextID = nil
        }
    }

    func selectAll() {
        guard let page = currentPage else { return }
        selection = Set(page.objects.filter { !$0.locked }.map(\.id))
    }

    func hitTest(pagePoint: CGPoint) -> CanvasObject? {
        guard let page = currentPage else { return nil }
        return DocumentEditorEngine.hitTest(page: page, point: pagePoint)
    }

    // MARK: - Edit ops

    func beginTextEdit(_ id: UUID) {
        selection = [id]
        editingTextID = id
        if let obj = scene.object(id: id)?.object, let text = obj.textValue {
            textEditDraft = text
        }
        status = "Editing text on canvas — press Done when finished."
    }

    func commitOpenTextEdit() {
        guard let id = editingTextID else { return }
        commitTextEdit(id: id, text: textEditDraft)
    }

    func commitTextEdit(id: UUID, text: String) {
        checkpoint()
        DocumentEditorEngine.setText(id: id, text: text, in: &scene)
        editingTextID = nil
        isDirty = true
        status = "Text updated."
        objectWillChange.send()
    }

    func endTextEdit() {
        editingTextID = nil
    }

    func moveSelection(by delta: CGSize) {
        guard !selection.isEmpty else { return }
        checkpoint()
        DocumentEditorEngine.move(ids: selection, by: delta, in: &scene)
        isDirty = true
        objectWillChange.send()
    }

    /// Continuous drag without flooding undo — call `endGesture()` after.
    private var gestureCheckpointTaken = false

    func beginGesture() {
        if !gestureCheckpointTaken {
            checkpoint()
            gestureCheckpointTaken = true
        }
    }

    func endGesture() {
        gestureCheckpointTaken = false
        isDirty = true
        status = "Moved."
        objectWillChange.send()
    }

    func dragSelection(by delta: CGSize) {
        beginGesture()
        DocumentEditorEngine.move(ids: selection, by: delta, in: &scene)
        objectWillChange.send()
    }

    func resizeSelected(to frame: CGRect) {
        guard let id = selection.first else { return }
        beginGesture()
        DocumentEditorEngine.setFrame(id: id, frame: frame, in: &scene)
        objectWillChange.send()
    }

    func rotateSelected(by degrees: Double) {
        guard let id = selection.first, var obj = primarySelection else { return }
        checkpoint()
        DocumentEditorEngine.setRotation(id: id, degrees: obj.rotation + degrees, in: &scene)
        isDirty = true
        objectWillChange.send()
    }

    func deleteSelection() {
        guard !selection.isEmpty else { return }
        checkpoint()
        DocumentEditorEngine.delete(ids: selection, in: &scene)
        selection = []
        editingTextID = nil
        isDirty = true
        status = "Deleted."
        objectWillChange.send()
    }

    func applyStyleToSelection(_ style: TextStyle) {
        guard !selection.isEmpty else { return }
        checkpoint()
        for id in selection {
            DocumentEditorEngine.setTextStyle(id: id, style: style, in: &scene)
        }
        isDirty = true
        status = "Style updated."
        objectWillChange.send()
    }

    func updatePrimaryTextStyle(_ mutate: (inout TextStyle) -> Void) {
        guard let id = selection.first, var style = primarySelection?.textStyle else { return }
        checkpoint()
        mutate(&style)
        DocumentEditorEngine.setTextStyle(id: id, style: style, in: &scene)
        isDirty = true
        objectWillChange.send()
    }

    // MARK: - Insert

    func canvasClick(at pagePoint: CGPoint) {
        switch tool {
        case .select:
            if let hit = hitTest(pagePoint: pagePoint) {
                select(id: hit.id)
            } else {
                select(id: nil)
            }
        case .text:
            checkpoint()
            let id = DocumentEditorEngine.addTextBox(
                onPage: currentPageIndex,
                at: pagePoint,
                in: &scene
            )
            selection = [id]
            editingTextID = id
            tool = .select
            isDirty = true
            status = "Text box added — type to edit."
            objectWillChange.send()
        case .shape:
            checkpoint()
            let frame = CGRect(x: pagePoint.x, y: pagePoint.y, width: 120, height: 80)
            let id = DocumentEditorEngine.addShape(onPage: currentPageIndex, frame: frame, in: &scene)
            selection = [id]
            tool = .select
            isDirty = true
            status = "Shape added."
            objectWillChange.send()
        case .table:
            checkpoint()
            let frame = CGRect(x: pagePoint.x, y: pagePoint.y, width: 280, height: 120)
            let id = DocumentEditorEngine.addTable(onPage: currentPageIndex, frame: frame, in: &scene)
            selection = [id]
            tool = .select
            isDirty = true
            status = "Table added."
            objectWillChange.send()
        case .image:
            status = "Use Insert Image… from the toolbar to place an image."
        }
    }

    func canvasDoubleClick(at pagePoint: CGPoint) {
        if let hit = hitTest(pagePoint: pagePoint), hit.isText {
            beginTextEdit(hit.id)
        }
    }

    func insertImage(url: URL) {
        guard let img = NSImage(contentsOf: url),
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            status = "Could not load image."
            return
        }
        checkpoint()
        let maxW: CGFloat = 300
        let scale = min(1, maxW / max(img.size.width, 1))
        let w = img.size.width * scale
        let h = img.size.height * scale
        let page = currentPage
        let x = ((page?.size.width ?? 612) - w) / 2
        let y = ((page?.size.height ?? 792) - h) / 2
        let obj = CanvasObject(
            frame: CGRect(x: x, y: y, width: w, height: h),
            kind: .image(.init(imageData: png))
        )
        scene.insertObject(obj, onPage: currentPageIndex)
        selection = [obj.id]
        isDirty = true
        status = "Image inserted."
        objectWillChange.send()
    }

    func insertBlankPage() {
        checkpoint()
        let size = currentPage?.size ?? CGSize(width: 612, height: 792)
        let page = DocPage(size: size)
        let idx = min(currentPageIndex + 1, scene.pages.count)
        scene.pages.insert(page, at: idx)
        currentPageIndex = idx
        selection = []
        isDirty = true
        status = "Page inserted."
        objectWillChange.send()
    }

    // MARK: - Find / replace on model

    func replaceAll() {
        guard !findQuery.isEmpty else {
            status = "Enter find text."
            return
        }
        checkpoint()
        let n = DocumentEditorEngine.replaceAll(
            find: findQuery,
            replace: replaceQuery,
            caseSensitive: caseSensitive,
            in: &scene
        )
        isDirty = n > 0
        status = n > 0 ? "Replaced \(n) occurrence(s) in text objects." : "No matches."
        objectWillChange.send()
    }

    // MARK: - AI

    func runAI() {
        let instruction = aiInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { return }
        aiBusy = true
        let plan = assistant.plan(instruction: instruction, scene: scene)
        aiPlan = plan
        aiBusy = false
        showAIPanel = true
        status = "AI plan ready — review preview, then Apply or Dismiss."
    }

    func applyAIPlan() {
        guard let plan = aiPlan else { return }
        checkpoint()
        scene = assistant.apply(plan)
        aiPlan = nil
        isDirty = true
        status = "AI changes applied. Undo available."
        objectWillChange.send()
    }

    func dismissAIPlan() {
        aiPlan = nil
        status = "AI plan discarded."
    }

    // MARK: - Save

    @discardableResult
    func save(to url: URL? = nil) throws -> URL {
        let target: URL
        if let url {
            target = url
        } else if let sourceURL {
            // Always save canvas docs as PDF for interchange
            if sourceURL.pathExtension.lowercased() == "pdf" {
                target = sourceURL
            } else {
                target = sourceURL.deletingPathExtension().appendingPathExtension("pdf")
            }
        } else {
            throw DocuForgeError.invalidInput("No save location.")
        }
        try DocumentExporter.exportPDF(scene, to: target)
        sourceURL = target
        isDirty = false
        status = "Saved \(target.lastPathComponent)"
        return target
    }
}
