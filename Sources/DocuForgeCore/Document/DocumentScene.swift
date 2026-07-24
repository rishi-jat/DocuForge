import Foundation
import CoreGraphics

/// Full multi-page editable document — source of truth for the WYSIWYG editor.
public struct DocumentScene: Codable, Sendable, Equatable {
    public var id: UUID
    public var title: String
    public var pages: [DocPage]
    public var createdAt: Date
    public var modifiedAt: Date

    public init(
        id: UUID = UUID(),
        title: String = "Untitled",
        pages: [DocPage] = [DocPage()],
        createdAt: Date = Date(),
        modifiedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.pages = pages.isEmpty ? [DocPage()] : pages
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

    public var pageCount: Int { pages.count }

    public mutating func touch() { modifiedAt = Date() }

    public func page(at index: Int) -> DocPage? {
        guard pages.indices.contains(index) else { return nil }
        return pages[index]
    }

    public mutating func updatePage(at index: Int, _ body: (inout DocPage) -> Void) {
        guard pages.indices.contains(index) else { return }
        body(&pages[index])
        touch()
    }

    public func object(id: UUID) -> (pageIndex: Int, object: CanvasObject)? {
        for (i, page) in pages.enumerated() {
            if let o = page.objects.first(where: { $0.id == id }) {
                return (i, o)
            }
        }
        return nil
    }

    public mutating func updateObject(id: UUID, _ body: (inout CanvasObject) -> Void) -> Bool {
        for i in pages.indices {
            if let j = pages[i].objects.firstIndex(where: { $0.id == id }) {
                body(&pages[i].objects[j])
                touch()
                return true
            }
        }
        return false
    }

    public mutating func removeObjects(ids: Set<UUID>) {
        for i in pages.indices {
            pages[i].objects.removeAll { ids.contains($0.id) }
        }
        touch()
    }

    public mutating func insertObject(_ object: CanvasObject, onPage pageIndex: Int) {
        guard pages.indices.contains(pageIndex) else { return }
        var obj = object
        obj.zIndex = (pages[pageIndex].objects.map(\.zIndex).max() ?? 0) + 1
        pages[pageIndex].objects.append(obj)
        touch()
    }
}

public struct DocPage: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    /// Page size in points (e.g. 612×792 US Letter).
    public var size: CGSize
    public var background: CodableColor
    public var objects: [CanvasObject]
    /// Optional raster backdrop (e.g. for visual reference); objects sit above it.
    public var backdropImageData: Data?

    public init(
        id: UUID = UUID(),
        size: CGSize = CGSize(width: 612, height: 792),
        background: CodableColor = .white,
        objects: [CanvasObject] = [],
        backdropImageData: Data? = nil
    ) {
        self.id = id
        self.size = size
        self.background = background
        self.objects = objects
        self.backdropImageData = backdropImageData
    }

    public var sortedObjects: [CanvasObject] {
        objects.sorted { $0.zIndex < $1.zIndex }
    }
}

// CGSize / CGRect are already Codable on Apple platforms.
