import Foundation
import AppKit

/// Offline EPUB reader: extract text/HTML from the ZIP package and render to PDF.
public actor EPUBService {
    private let pdf = PDFService()

    public init() {}

    public func extractText(from url: URL) throws -> String {
        let names = try OfficeOpenXML.zipList(url: url)
        // Prefer reading order from package.opf spine when present
        let opf = names.first { $0.hasSuffix(".opf") || $0.contains("content.opf") || $0.contains("package.opf") }
        var htmlPaths: [String] = []
        if let opf, let data = try? OfficeOpenXML.zipRead(url: url, entry: opf) {
            htmlPaths = spinePaths(from: data, names: names)
        }
        if htmlPaths.isEmpty {
            htmlPaths = names.filter {
                let l = $0.lowercased()
                return l.hasSuffix(".xhtml") || l.hasSuffix(".html") || l.hasSuffix(".htm")
            }.sorted()
        }

        var parts: [String] = []
        for path in htmlPaths {
            guard let data = try? OfficeOpenXML.zipRead(url: url, entry: path) else { continue }
            let html = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
                ?? ""
            let text = stripHTML(html)
            if !text.isEmpty { parts.append(text) }
        }
        let joined = parts.joined(separator: "\n\n")
        if joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw DocuForgeError.conversionFailed("No extractable text found in EPUB.")
        }
        return joined
    }

    public func convert(
        url: URL,
        to target: DocumentFormat,
        outputDirectory: URL
    ) async throws -> ProcessingResult {
        let base = url.deletingPathExtension().lastPathComponent
        let text = try extractText(from: url)

        switch target {
        case .txt:
            let out = outputDirectory.appendingPathComponent("\(base).txt")
            try text.write(to: out, atomically: true, encoding: .utf8)
            return ProcessingResult(
                outputURLs: [out],
                bytesIn: FileIO.fileSize(at: url),
                bytesOut: FileIO.fileSize(at: out),
                notes: ["Extracted EPUB text content."]
            )
        case .html:
            let out = outputDirectory.appendingPathComponent("\(base).html")
            let html = "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>\(base)</title></head><body><pre>\(htmlEscape(text))</pre></body></html>"
            try html.write(to: out, atomically: true, encoding: .utf8)
            return ProcessingResult(
                outputURLs: [out],
                bytesIn: FileIO.fileSize(at: url),
                bytesOut: FileIO.fileSize(at: out)
            )
        case .pdf:
            let out = outputDirectory.appendingPathComponent("\(base).pdf")
            let result = try await pdf.textToPDF(text: text, title: base, outputURL: out)
            return ProcessingResult(
                outputURLs: result.outputURLs,
                bytesIn: FileIO.fileSize(at: url),
                bytesOut: result.bytesOut,
                notes: ["EPUB text rendered to PDF (layout simplified)."]
            )
        default:
            throw DocuForgeError.conversionFailed("EPUB converts to TXT, HTML, or PDF.")
        }
    }

    private func spinePaths(from opfData: Data, names: [String]) -> [String] {
        guard let xml = String(data: opfData, encoding: .utf8) else { return [] }
        // Very small spine parser: collect itemref idrefs and map via manifest hrefs
        var idToHref: [String: String] = [:]
        let manifestPattern = #"id="([^"]+)"[^>]*href="([^"]+)""#
        if let regex = try? NSRegularExpression(pattern: manifestPattern) {
            let range = NSRange(xml.startIndex..., in: xml)
            regex.enumerateMatches(in: xml, range: range) { match, _, _ in
                guard let match,
                      let idR = Range(match.range(at: 1), in: xml),
                      let hrefR = Range(match.range(at: 2), in: xml) else { return }
                idToHref[String(xml[idR])] = String(xml[hrefR])
            }
        }
        // Also try href before id
        let manifestPattern2 = #"href="([^"]+)"[^>]*id="([^"]+)""#
        if let regex = try? NSRegularExpression(pattern: manifestPattern2) {
            let range = NSRange(xml.startIndex..., in: xml)
            regex.enumerateMatches(in: xml, range: range) { match, _, _ in
                guard let match,
                      let hrefR = Range(match.range(at: 1), in: xml),
                      let idR = Range(match.range(at: 2), in: xml) else { return }
                idToHref[String(xml[idR])] = String(xml[hrefR])
            }
        }

        var order: [String] = []
        let itemrefPattern = #"idref="([^"]+)""#
        if let regex = try? NSRegularExpression(pattern: itemrefPattern) {
            let range = NSRange(xml.startIndex..., in: xml)
            regex.enumerateMatches(in: xml, range: range) { match, _, _ in
                guard let match, let idR = Range(match.range(at: 1), in: xml) else { return }
                let id = String(xml[idR])
                if let href = idToHref[id] {
                    // Resolve against zip names
                    if names.contains(href) {
                        order.append(href)
                    } else if let match = names.first(where: { $0.hasSuffix(href) || $0.hasSuffix("/" + href) }) {
                        order.append(match)
                    }
                }
            }
        }
        return order
    }

    private func stripHTML(_ html: String) -> String {
        var s = html
        // Remove scripts/styles
        s = s.replacingOccurrences(of: #"<script[\s\S]*?</script>"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<style[\s\S]*?</style>"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "&nbsp;", with: " ")
        s = s.replacingOccurrences(of: "&amp;", with: "&")
        s = s.replacingOccurrences(of: "&lt;", with: "<")
        s = s.replacingOccurrences(of: "&gt;", with: ">")
        s = s.replacingOccurrences(of: "&quot;", with: "\"")
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func htmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
