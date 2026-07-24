import Foundation
import CoreGraphics

/// A selectable, transformable object on a page (Pages/Canva/Figma model).
public struct CanvasObject: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var frame: CGRect          // top-left origin, page space (points)
    public var rotation: Double       // degrees
    public var zIndex: Int
    public var locked: Bool
    public var name: String
    public var kind: ObjectKind

    public init(
        id: UUID = UUID(),
        frame: CGRect,
        rotation: Double = 0,
        zIndex: Int = 0,
        locked: Bool = false,
        name: String = "",
        kind: ObjectKind
    ) {
        self.id = id
        self.frame = frame
        self.rotation = rotation
        self.zIndex = zIndex
        self.locked = locked
        self.name = name
        self.kind = kind
    }

    public enum ObjectKind: Codable, Sendable, Equatable {
        case text(TextContent)
        case image(ImageContent)
        case shape(ShapeContent)
        case table(TableContent)
    }

    public struct TextContent: Codable, Sendable, Equatable {
        public var text: String
        public var style: TextStyle

        public init(text: String, style: TextStyle = .body) {
            self.text = text
            self.style = style
        }
    }

    public struct ImageContent: Codable, Sendable, Equatable {
        /// PNG/JPEG bytes embedded in the scene (offline-first).
        public var imageData: Data
        public var cropNormalized: CGRect? // 0...1 in image space

        public init(imageData: Data, cropNormalized: CGRect? = nil) {
            self.imageData = imageData
            self.cropNormalized = cropNormalized
        }
    }

    public struct ShapeContent: Codable, Sendable, Equatable {
        public var shape: ShapeKind
        public var fill: CodableColor
        public var stroke: CodableColor
        public var strokeWidth: CGFloat

        public init(
            shape: ShapeKind = .rectangle,
            fill: CodableColor = .clear,
            stroke: CodableColor = .black,
            strokeWidth: CGFloat = 1
        ) {
            self.shape = shape
            self.fill = fill
            self.stroke = stroke
            self.strokeWidth = strokeWidth
        }
    }

    public struct TableContent: Codable, Sendable, Equatable {
        public var rows: Int
        public var columns: Int
        public var cells: [[TableCell]]
        public var style: TextStyle

        public init(rows: Int = 2, columns: Int = 2, style: TextStyle = .body) {
            let r = max(1, rows)
            let c = max(1, columns)
            self.rows = r
            self.columns = c
            self.style = style
            self.cells = (0..<r).map { _ in
                (0..<c).map { _ in TableCell() }
            }
        }
    }

    public var isText: Bool {
        if case .text = kind { return true }
        return false
    }

    public var textValue: String? {
        if case .text(let c) = kind { return c.text }
        return nil
    }

    public mutating func setText(_ text: String) {
        guard case .text(var c) = kind else { return }
        c.text = text
        kind = .text(c)
    }

    public mutating func setTextStyle(_ style: TextStyle) {
        guard case .text(var c) = kind else { return }
        c.style = style
        kind = .text(c)
    }

    public var textStyle: TextStyle? {
        if case .text(let c) = kind { return c.style }
        return nil
    }
}
