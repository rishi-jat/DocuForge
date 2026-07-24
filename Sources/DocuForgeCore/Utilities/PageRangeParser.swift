import Foundation

/// Parses human page-range strings like "1-3, 5, 8-10" into ranges (1-based inclusive).
public enum PageRangeParser {
    public static func parse(_ text: String, pageCount: Int) throws -> [PageRange] {
        let cleaned = text.replacingOccurrences(of: " ", with: "")
        guard !cleaned.isEmpty else {
            throw DocuForgeError.invalidInput("Enter page ranges such as 1-3, 5, 8-10.")
        }
        var result: [PageRange] = []
        for part in cleaned.split(separator: ",") {
            if part.contains("-") {
                let bits = part.split(separator: "-")
                guard bits.count == 2,
                      let start = Int(bits[0]),
                      let end = Int(bits[1]) else {
                    throw DocuForgeError.invalidInput("Invalid range: \(part)")
                }
                guard start >= 1, end <= pageCount, start <= end else {
                    throw DocuForgeError.invalidInput("Range \(part) is out of bounds (1–\(pageCount)).")
                }
                result.append(PageRange(start: start, end: end))
            } else {
                guard let page = Int(part) else {
                    throw DocuForgeError.invalidInput("Invalid page: \(part)")
                }
                guard page >= 1, page <= pageCount else {
                    throw DocuForgeError.invalidInput("Page \(page) is out of bounds (1–\(pageCount)).")
                }
                result.append(PageRange(start: page, end: page))
            }
        }
        return result
    }
}
