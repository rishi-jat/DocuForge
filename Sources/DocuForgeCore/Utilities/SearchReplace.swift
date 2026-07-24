import Foundation

/// Case-sensitive/insensitive multi-occurrence search & replace for document text.
public enum SearchReplace: Sendable {
    public struct Result: Sendable {
        public let output: String
        public let matchCount: Int
        public let replacedCount: Int
    }

    public static func countMatches(
        in text: String,
        search: String,
        caseSensitive: Bool
    ) -> Int {
        guard !search.isEmpty else { return 0 }
        if caseSensitive {
            return text.components(separatedBy: search).count - 1
        }
        let lower = text.lowercased()
        let needle = search.lowercased()
        return lower.components(separatedBy: needle).count - 1
    }

    public static func replaceAll(
        in text: String,
        search: String,
        replace: String,
        caseSensitive: Bool
    ) -> Result {
        guard !search.isEmpty else {
            return Result(output: text, matchCount: 0, replacedCount: 0)
        }
        let count = countMatches(in: text, search: search, caseSensitive: caseSensitive)
        guard count > 0 else {
            return Result(output: text, matchCount: 0, replacedCount: 0)
        }
        if caseSensitive {
            let out = text.replacingOccurrences(of: search, with: replace)
            return Result(output: out, matchCount: count, replacedCount: count)
        }
        // Case-insensitive replace preserving non-overlapping matches
        var result = ""
        var remainder = text
        let needle = search.lowercased()
        var replaced = 0
        while true {
            guard let range = remainder.range(of: needle, options: .caseInsensitive) else {
                result += remainder
                break
            }
            result += remainder[..<range.lowerBound]
            result += replace
            remainder = String(remainder[range.upperBound...])
            replaced += 1
        }
        return Result(output: result, matchCount: count, replacedCount: replaced)
    }
}
