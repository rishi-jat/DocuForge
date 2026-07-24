import Foundation
import CoreGraphics

/// Shared geometric / style primitives for the WYSIWYG document model.
/// Coordinate system: **top-left origin**, y grows downward (SwiftUI-friendly).

public struct CodableColor: Codable, Sendable, Equatable, Hashable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    public static let black = CodableColor(r: 0.05, g: 0.05, b: 0.05)
    public static let white = CodableColor(r: 1, g: 1, b: 1)
    public static let blue = CodableColor(r: 0.0, g: 0.35, b: 0.85)
    public static let red = CodableColor(r: 0.85, g: 0.15, b: 0.15)
    public static let clear = CodableColor(r: 0, g: 0, b: 0, a: 0)
}

public struct TextStyle: Codable, Sendable, Equatable {
    public var fontName: String
    public var fontSize: CGFloat
    public var bold: Bool
    public var italic: Bool
    public var color: CodableColor
    public var alignment: TextHAlignment

    public init(
        fontName: String = "Helvetica",
        fontSize: CGFloat = 12,
        bold: Bool = false,
        italic: Bool = false,
        color: CodableColor = .black,
        alignment: TextHAlignment = .leading
    ) {
        self.fontName = fontName
        self.fontSize = fontSize
        self.bold = bold
        self.italic = italic
        self.color = color
        self.alignment = alignment
    }

    public static func heading(_ size: CGFloat = 24) -> TextStyle {
        TextStyle(fontName: "Helvetica", fontSize: size, bold: true)
    }

    public static var body: TextStyle { TextStyle(fontSize: 12) }
}

public enum TextHAlignment: String, Codable, Sendable, Equatable {
    case leading, center, trailing
}

public enum ShapeKind: String, Codable, Sendable, Equatable {
    case rectangle
    case ellipse
    case line
}

public struct TableCell: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var text: String

    public init(id: UUID = UUID(), text: String = "") {
        self.id = id
        self.text = text
    }
}
