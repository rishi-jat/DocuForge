import Foundation
import CoreGraphics

/// Pure engine for mutating a document scene (testable without UI).
public enum DocumentEditorEngine {

    public static func move(ids: Set<UUID>, by delta: CGSize, in scene: inout DocumentScene) {
        for id in ids {
            _ = scene.updateObject(id: id) { obj in
                guard !obj.locked else { return }
                obj.frame.origin.x += delta.width
                obj.frame.origin.y += delta.height
            }
        }
    }

    public static func setFrame(id: UUID, frame: CGRect, in scene: inout DocumentScene) {
        _ = scene.updateObject(id: id) { obj in
            guard !obj.locked else { return }
            obj.frame = frame
        }
    }

    public static func setRotation(id: UUID, degrees: Double, in scene: inout DocumentScene) {
        _ = scene.updateObject(id: id) { obj in
            guard !obj.locked else { return }
            obj.rotation = degrees
        }
    }

    public static func setText(id: UUID, text: String, in scene: inout DocumentScene) {
        _ = scene.updateObject(id: id) { obj in
            obj.setText(text)
        }
    }

    public static func setTextStyle(id: UUID, style: TextStyle, in scene: inout DocumentScene) {
        _ = scene.updateObject(id: id) { obj in
            obj.setTextStyle(style)
        }
    }

    public static func delete(ids: Set<UUID>, in scene: inout DocumentScene) {
        scene.removeObjects(ids: ids)
    }

    public static func addTextBox(
        onPage pageIndex: Int,
        at point: CGPoint,
        text: String = "New text",
        style: TextStyle = .body,
        in scene: inout DocumentScene
    ) -> UUID {
        let id = UUID()
        let frame = CGRect(x: point.x, y: point.y, width: 200, height: style.fontSize * 1.5)
        let obj = CanvasObject(
            id: id,
            frame: frame,
            kind: .text(.init(text: text, style: style))
        )
        scene.insertObject(obj, onPage: pageIndex)
        return id
    }

    public static func addShape(
        onPage pageIndex: Int,
        frame: CGRect,
        shape: ShapeKind = .rectangle,
        in scene: inout DocumentScene
    ) -> UUID {
        let id = UUID()
        let obj = CanvasObject(
            id: id,
            frame: frame,
            kind: .shape(.init(shape: shape, fill: CodableColor(r: 0.9, g: 0.92, b: 0.98), stroke: .blue, strokeWidth: 1))
        )
        scene.insertObject(obj, onPage: pageIndex)
        return id
    }

    public static func addTable(
        onPage pageIndex: Int,
        frame: CGRect,
        rows: Int = 3,
        columns: Int = 3,
        in scene: inout DocumentScene
    ) -> UUID {
        let id = UUID()
        let obj = CanvasObject(
            id: id,
            frame: frame,
            kind: .table(.init(rows: rows, columns: columns))
        )
        scene.insertObject(obj, onPage: pageIndex)
        return id
    }

    public static func replaceAll(
        find: String,
        replace: String,
        caseSensitive: Bool,
        in scene: inout DocumentScene
    ) -> Int {
        var count = 0
        for pi in scene.pages.indices {
            for oi in scene.pages[pi].objects.indices {
                guard case .text(var c) = scene.pages[pi].objects[oi].kind else { continue }
                let before = c.text
                if caseSensitive {
                    c.text = c.text.replacingOccurrences(of: find, with: replace)
                } else {
                    c.text = c.text.replacingOccurrences(of: find, with: replace, options: .caseInsensitive)
                }
                if c.text != before {
                    count += SearchReplace.countMatches(in: before, search: find, caseSensitive: caseSensitive)
                    scene.pages[pi].objects[oi].kind = .text(c)
                }
            }
        }
        if count > 0 { scene.touch() }
        return count
    }

    public static func hitTest(page: DocPage, point: CGPoint) -> CanvasObject? {
        // Topmost first
        for obj in page.sortedObjects.reversed() {
            if objectFrame(obj).contains(point) {
                return obj
            }
        }
        return nil
    }

    public static func objectFrame(_ obj: CanvasObject) -> CGRect {
        obj.frame
    }
}
