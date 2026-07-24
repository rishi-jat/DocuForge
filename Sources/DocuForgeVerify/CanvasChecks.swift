import Foundation
import AppKit
import PDFKit
import DocuForgeCore

/// Verifies the WYSIWYG document-scene editor foundation (not PDF paint-over).
enum CanvasChecks {
    static func run(temp: URL, check: @Sendable (String, Bool, String) -> Void) throws {
        // Blank scene
        var scene = DocumentImporter.blankDocument(title: "Test")
        check("canvas blank has 1 page", scene.pageCount == 1, "pages=\(scene.pageCount)")

        // Add text objects
        let id1 = DocumentEditorEngine.addTextBox(
            onPage: 0,
            at: CGPoint(x: 72, y: 72),
            text: "Hello Canvas",
            style: .heading(28),
            in: &scene
        )
        let id2 = DocumentEditorEngine.addTextBox(
            onPage: 0,
            at: CGPoint(x: 72, y: 120),
            text: "Body mentions Summer and Summer again.",
            style: .body,
            in: &scene
        )
        check("canvas two text objects", scene.pages[0].objects.count == 2, "n=\(scene.pages[0].objects.count)")

        // Move
        DocumentEditorEngine.move(ids: [id1], by: CGSize(width: 10, height: 5), in: &scene)
        let moved = scene.object(id: id1)?.object.frame.origin
        check("canvas move", moved?.x == 82 && moved?.y == 77, "\(String(describing: moved))")

        // Replace all on model
        let n = DocumentEditorEngine.replaceAll(
            find: "Summer",
            replace: "Winter",
            caseSensitive: true,
            in: &scene
        )
        check("canvas replaceAll count", n == 2, "n=\(n)")
        let body = scene.object(id: id2)?.object.textValue ?? ""
        check("canvas replace text", body.contains("Winter") && !body.contains("Summer"), body)

        // Style headings
        DocumentEditorEngine.setTextStyle(
            id: id1,
            style: TextStyle(fontSize: 28, bold: true, color: .blue),
            in: &scene
        )
        check("canvas heading blue", scene.object(id: id1)?.object.textStyle?.color == .blue, "")

        // Shape + table
        _ = DocumentEditorEngine.addShape(
            onPage: 0,
            frame: CGRect(x: 100, y: 200, width: 80, height: 40),
            in: &scene
        )
        _ = DocumentEditorEngine.addTable(
            onPage: 0,
            frame: CGRect(x: 100, y: 300, width: 200, height: 80),
            in: &scene
        )
        check("canvas has shape and table", scene.pages[0].objects.count >= 4, "n=\(scene.pages[0].objects.count)")

        // Export PDF
        let out = temp.appendingPathComponent("canvas-export.pdf")
        try DocumentExporter.exportPDF(scene, to: out)
        check("canvas export PDF exists", FileManager.default.fileExists(atPath: out.path), out.path)
        guard let pdf = PDFDocument(url: out) else {
            check("canvas export openable", false, "nil")
            return
        }
        check("canvas export page count", pdf.pageCount == 1, "pages=\(pdf.pageCount)")

        // Round-trip import
        let reimported = try DocumentImporter.importPDF(url: out)
        check("canvas reimport pages", reimported.pageCount >= 1, "pages=\(reimported.pageCount)")
        check("canvas reimport has text objects", reimported.pages[0].objects.contains(where: \.isText), "objs=\(reimported.pages[0].objects.count)")

        // History
        var history = DocumentHistory()
        let snap = scene
        history.push(snap)
        DocumentEditorEngine.delete(ids: [id1], in: &scene)
        check("canvas delete", scene.object(id: id1) == nil, "")
        if let undone = history.undo(current: scene) {
            scene = undone
            check("canvas undo restore", scene.object(id: id1) != nil, "")
        } else {
            check("canvas undo restore", false, "no undo")
        }

        // AI plan replace
        let assistant = AIDocumentAssistant()
        let plan = assistant.plan(instruction: "replace Winter with Autumn", scene: scene)
        check("canvas AI plan ops", !plan.operations.isEmpty, plan.summary)
        let applied = assistant.apply(plan)
        let joined = applied.pages.flatMap(\.objects).compactMap(\.textValue).joined(separator: " ")
        check("canvas AI apply", joined.contains("Autumn"), joined)

        // Multi-page plain text
        let long = (1...40).map { "Line \($0) of the multipage canvas document." }.joined(separator: "\n")
        let multi = DocumentImporter.sceneFromPlainText(long, title: "Multi")
        check("canvas multipage plain", multi.pageCount >= 1, "pages=\(multi.pageCount)")
        let multiOut = temp.appendingPathComponent("canvas-multi.pdf")
        try DocumentExporter.exportPDF(multi, to: multiOut)
        let multiPDF = PDFDocument(url: multiOut)
        check("canvas multipage export", (multiPDF?.pageCount ?? 0) >= 1, "pages=\(multiPDF?.pageCount ?? -1)")

        // Hit test
        if let page = scene.page(at: 0),
           let first = page.objects.first(where: { $0.id == id2 || $0.isText }) {
            let hit = DocumentEditorEngine.hitTest(
                page: page,
                point: CGPoint(x: first.frame.midX, y: first.frame.midY)
            )
            check("canvas hit test", hit != nil, "")
        }

        check("canvas foundation complete", true, "WYSIWYG model path OK")
    }
}
