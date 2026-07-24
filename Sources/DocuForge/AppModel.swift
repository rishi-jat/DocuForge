import SwiftUI
import AppKit
import UniformTypeIdentifiers
import DocuForgeCore

@MainActor
final class AppModel: ObservableObject {
    @Published var selectedTool: ToolKind = .edit
    @Published var recentOutputs: [URL] = []
    @Published var preferredOutputInDownloads: Bool = true

    let pdf = PDFService()
    let images = ImageService()
    let ocr = OCRService()
    let conversion = ConversionService()
    let batch = BatchProcessor()
    let pdfEditor = PDFEditorService()
    let imageEditor = ImageEditorService()
    let textEditor = TextEditorService()
    let screenshotText = ScreenshotTextEditorService()

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func recordOutputs(_ urls: [URL]) {
        recentOutputs = (urls + recentOutputs).uniqued().prefix(20).map { $0 }
    }

    func makeOutputDirectory(named name: String) throws -> URL {
        if preferredOutputInDownloads {
            return try FileIO.downloadsOutputDirectory(named: name)
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocuForge-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func pickFiles(contentTypes: [UTType], allowsMultiple: Bool = true) -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = allowsMultiple
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = contentTypes.isEmpty ? [.item] : contentTypes
        return panel.runModal() == .OK ? panel.urls : []
    }

    func pickSaveURL(name: String, contentType: UTType) -> URL? {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [contentType]
        return panel.runModal() == .OK ? panel.url : nil
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
