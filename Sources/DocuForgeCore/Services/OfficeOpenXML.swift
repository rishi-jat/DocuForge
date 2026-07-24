import Foundation

/// Minimal offline readers for Office Open XML packages (DOCX / PPTX / XLSX).
/// These formats are ZIP archives containing XML parts. We extract text for
/// conversion to PDF/TXT without third-party dependencies.
public enum OfficeOpenXML: Sendable {

    public static func extractText(from url: URL, format: DocumentFormat) throws -> String {
        switch format {
        case .docx:
            let xmlData = try zipRead(url: url, entry: "word/document.xml")
            return extractXMLText(from: xmlData, textLocalNames: ["t"])
        case .pptx:
            // List slide parts then extract each
            let names = try zipList(url: url).filter {
                $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml")
            }.sorted()
            var parts: [String] = []
            for name in names {
                if let data = try? zipRead(url: url, entry: name) {
                    let text = extractXMLText(from: data, textLocalNames: ["t"])
                    if !text.isEmpty { parts.append(text) }
                }
            }
            return parts.joined(separator: "\n\n")
        case .xlsx:
            let shared: String
            if let data = try? zipRead(url: url, entry: "xl/sharedStrings.xml") {
                shared = extractXMLText(from: data, textLocalNames: ["t"])
            } else {
                shared = ""
            }
            let sheets = try zipList(url: url).filter {
                $0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".xml")
            }.sorted()
            var sheetTexts: [String] = []
            for name in sheets {
                if let data = try? zipRead(url: url, entry: name) {
                    let inline = extractXMLText(from: data, textLocalNames: ["v", "t"])
                    if !inline.isEmpty { sheetTexts.append(inline) }
                }
            }
            if !shared.isEmpty {
                return ([shared] + sheetTexts).joined(separator: "\n")
            }
            return sheetTexts.joined(separator: "\n")
        default:
            throw DocuForgeError.unsupportedFormat(format)
        }
    }

    // MARK: - ZIP via system unzip (handles store + deflate offline)

    public static func zipRead(url: URL, entry: String) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", url.path, entry]
        let pipe = Pipe()
        let err = Pipe()
        process.standardOutput = pipe
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0, !data.isEmpty else {
            throw DocuForgeError.conversionFailed("Could not read \(entry) from \(url.lastPathComponent)")
        }
        return data
    }

    public static func zipList(url: URL) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-Z", "-1", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw DocuForgeError.conversionFailed("Could not list archive \(url.lastPathComponent)")
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.split(whereSeparator: \.isNewline).map(String.init)
    }

    public static func zipReadOptional(url: URL, entry: String) -> Data? {
        try? zipRead(url: url, entry: entry)
    }

    private static func extractXMLText(from data: Data, textLocalNames: Set<String>) -> String {
        let parser = TextXMLParser(localNames: textLocalNames)
        let xml = XMLParser(data: data)
        xml.delegate = parser
        xml.parse()
        return parser.pieces.joined(separator: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class TextXMLParser: NSObject, XMLParserDelegate, @unchecked Sendable {
    let localNames: Set<String>
    var pieces: [String] = []
    private var capture = false
    private var buffer = ""

    init(localNames: Set<String>) {
        self.localNames = localNames
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
        if localNames.contains(local) {
            capture = true
            buffer = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capture { buffer += string }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
        if localNames.contains(local), capture {
            let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { pieces.append(trimmed) }
            capture = false
            buffer = ""
        }
    }
}
