import Foundation

/// Snapshot-based undo/redo for the document scene (non-destructive AI applies use the same stack).
public struct DocumentHistory: Sendable {
    private var undoStack: [DocumentScene] = []
    private var redoStack: [DocumentScene] = []
    public var limit: Int

    public init(limit: Int = 50) {
        self.limit = limit
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public mutating func push(_ scene: DocumentScene) {
        undoStack.append(scene)
        if undoStack.count > limit {
            undoStack.removeFirst(undoStack.count - limit)
        }
        redoStack.removeAll()
    }

    public mutating func undo(current: DocumentScene) -> DocumentScene? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current)
        return previous
    }

    public mutating func redo(current: DocumentScene) -> DocumentScene? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        return next
    }

    public mutating func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
    }
}
