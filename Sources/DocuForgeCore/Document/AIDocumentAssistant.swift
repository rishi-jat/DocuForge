import Foundation
import CoreGraphics

/// AI (and rule-based) assistant that plans edits against the **document scene**,
/// never against OCR side-panels or glyph burns. Preview → accept → undo.
public struct AIDocumentAssistant: Sendable {

    public init() {}

    public struct Plan: Sendable, Equatable {
        public var title: String
        public var summary: String
        public var operations: [Operation]
        /// Scene after applying operations (preview).
        public var previewScene: DocumentScene

        public init(title: String, summary: String, operations: [Operation], previewScene: DocumentScene) {
            self.title = title
            self.summary = summary
            self.operations = operations
            self.previewScene = previewScene
        }
    }

    public enum Operation: Sendable, Equatable {
        case replaceText(find: String, replace: String, caseSensitive: Bool)
        case setHeadingColor(CodableColor)
        case setAllTextColor(CodableColor)
        case rewriteTextObject(id: UUID, newText: String)
        case boldHeadings
        case deleteMatchingText(String)
        case insertTextBox(pageIndex: Int, text: String)
        case note(String) // informational only
    }

    /// Parse natural-language instruction into a plan (deterministic rules first;
    /// structured enough for an LLM backend to extend later).
    public func plan(instruction: String, scene: DocumentScene) -> Plan {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        var ops: [Operation] = []
        var working = scene

        // replace X with Y / replace every occurrence of X with Y
        if let (find, replace) = parseReplace(trimmed) {
            ops.append(.replaceText(find: find, replace: replace, caseSensitive: false))
            working = applyReplace(working, find: find, replace: replace, caseSensitive: false)
            return Plan(
                title: "Replace text",
                summary: "Replace “\(find)” → “\(replace)” across the document.",
                operations: ops,
                previewScene: working
            )
        }

        // change all headings to blue / make headings blue
        if lower.contains("heading") && (lower.contains("blue") || lower.contains("color")) {
            let color: CodableColor = lower.contains("red") ? .red : .blue
            ops.append(.setHeadingColor(color))
            working = applyHeadingColor(working, color: color)
            return Plan(
                title: "Style headings",
                summary: "Set color on heading-sized text (≥16pt or bold large).",
                operations: ops,
                previewScene: working
            )
        }

        // make all text blue
        if lower.contains("all text") && lower.contains("blue") {
            ops.append(.setAllTextColor(.blue))
            working = applyAllTextColor(working, color: .blue)
            return Plan(
                title: "Color all text",
                summary: "Set every text object to blue.",
                operations: ops,
                previewScene: working
            )
        }

        // bold headings
        if lower.contains("bold") && lower.contains("heading") {
            ops.append(.boldHeadings)
            working = applyBoldHeadings(working)
            return Plan(
                title: "Bold headings",
                summary: "Mark large text objects as bold.",
                operations: ops,
                previewScene: working
            )
        }

        // summarize page N (read-only note)
        if lower.hasPrefix("summarize") || lower.contains("summarize page") {
            let pageNum = extractPageNumber(lower) ?? 1
            let idx = max(0, pageNum - 1)
            let text = pageText(scene, pageIndex: idx)
            let summary = summarizeLocally(text)
            ops.append(.note(summary))
            return Plan(
                title: "Summarize page \(pageNum)",
                summary: summary,
                operations: ops,
                previewScene: scene
            )
        }

        // rewrite professionally (local light rewrite of first selected-looking long paragraph)
        if lower.contains("rewrite") || lower.contains("professionally") {
            var count = 0
            for pi in working.pages.indices {
                for oi in working.pages[pi].objects.indices {
                    guard case .text(var c) = working.pages[pi].objects[oi].kind else { continue }
                    if c.text.count > 80 {
                        let newText = professionalize(c.text)
                        ops.append(.rewriteTextObject(id: working.pages[pi].objects[oi].id, newText: newText))
                        c.text = newText
                        working.pages[pi].objects[oi].kind = .text(c)
                        count += 1
                        if count >= 3 { break }
                    }
                }
                if count >= 3 { break }
            }
            working.touch()
            return Plan(
                title: "Rewrite paragraphs",
                summary: "Polished \(count) long paragraph(s) with local rules (offline). Connect an LLM for higher quality.",
                operations: ops,
                previewScene: working
            )
        }

        // translate to french — local stub note
        if lower.contains("translate") {
            let lang = lower.contains("french") ? "French" : "the target language"
            return Plan(
                title: "Translate",
                summary: "Translation to \(lang) needs an LLM backend. Scene is ready for per-frame string replace when AI is connected.",
                operations: [.note("Connect AI provider to translate to \(lang).")],
                previewScene: scene
            )
        }

        // fix grammar — light local
        if lower.contains("grammar") || lower.contains("fix grammar") {
            var n = 0
            for pi in working.pages.indices {
                for oi in working.pages[pi].objects.indices {
                    guard case .text(var c) = working.pages[pi].objects[oi].kind else { continue }
                    let fixed = basicGrammar(c.text)
                    if fixed != c.text {
                        ops.append(.rewriteTextObject(id: working.pages[pi].objects[oi].id, newText: fixed))
                        c.text = fixed
                        working.pages[pi].objects[oi].kind = .text(c)
                        n += 1
                    }
                }
            }
            working.touch()
            return Plan(
                title: "Fix grammar",
                summary: "Applied basic offline grammar fixes to \(n) text object(s).",
                operations: ops,
                previewScene: working
            )
        }

        return Plan(
            title: "Could not parse",
            summary: "Try: “replace John with Rishi”, “change all headings to blue”, “bold headings”, “summarize page 1”, “fix grammar”, “rewrite professionally”.",
            operations: [.note(trimmed)],
            previewScene: scene
        )
    }

    public func apply(_ plan: Plan) -> DocumentScene {
        plan.previewScene
    }

    // MARK: - Parsers & transforms

    private func parseReplace(_ instruction: String) -> (String, String)? {
        // replace X with Y | replace every occurrence of X with Y | change X to Y
        let patterns = [
            #"(?i)replace\s+(?:every\s+occurrence\s+of\s+)?[“"']?(.+?)[”"']?\s+with\s+[“"']?(.+?)[”"']?\s*$"#,
            #"(?i)change\s+[“"']?(.+?)[”"']?\s+to\s+[“"']?(.+?)[”"']?\s*$"#
        ]
        for p in patterns {
            if let re = try? NSRegularExpression(pattern: p),
               let m = re.firstMatch(in: instruction, range: NSRange(instruction.startIndex..., in: instruction)),
               m.numberOfRanges >= 3,
               let r1 = Range(m.range(at: 1), in: instruction),
               let r2 = Range(m.range(at: 2), in: instruction) {
                let a = String(instruction[r1]).trimmingCharacters(in: .whitespacesAndNewlines)
                let b = String(instruction[r2]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !a.isEmpty { return (a, b) }
            }
        }
        return nil
    }

    private func applyReplace(_ scene: DocumentScene, find: String, replace: String, caseSensitive: Bool) -> DocumentScene {
        var s = scene
        for pi in s.pages.indices {
            for oi in s.pages[pi].objects.indices {
                guard case .text(var c) = s.pages[pi].objects[oi].kind else { continue }
                if caseSensitive {
                    c.text = c.text.replacingOccurrences(of: find, with: replace)
                } else {
                    c.text = c.text.replacingOccurrences(of: find, with: replace, options: .caseInsensitive)
                }
                s.pages[pi].objects[oi].kind = .text(c)
            }
        }
        s.touch()
        return s
    }

    private func applyHeadingColor(_ scene: DocumentScene, color: CodableColor) -> DocumentScene {
        var s = scene
        for pi in s.pages.indices {
            for oi in s.pages[pi].objects.indices {
                guard case .text(var c) = s.pages[pi].objects[oi].kind else { continue }
                if c.style.fontSize >= 16 || (c.style.bold && c.style.fontSize >= 14) {
                    c.style.color = color
                    s.pages[pi].objects[oi].kind = .text(c)
                }
            }
        }
        s.touch()
        return s
    }

    private func applyAllTextColor(_ scene: DocumentScene, color: CodableColor) -> DocumentScene {
        var s = scene
        for pi in s.pages.indices {
            for oi in s.pages[pi].objects.indices {
                guard case .text(var c) = s.pages[pi].objects[oi].kind else { continue }
                c.style.color = color
                s.pages[pi].objects[oi].kind = .text(c)
            }
        }
        s.touch()
        return s
    }

    private func applyBoldHeadings(_ scene: DocumentScene) -> DocumentScene {
        var s = scene
        for pi in s.pages.indices {
            for oi in s.pages[pi].objects.indices {
                guard case .text(var c) = s.pages[pi].objects[oi].kind else { continue }
                if c.style.fontSize >= 16 {
                    c.style.bold = true
                    s.pages[pi].objects[oi].kind = .text(c)
                }
            }
        }
        s.touch()
        return s
    }

    private func pageText(_ scene: DocumentScene, pageIndex: Int) -> String {
        guard let page = scene.page(at: pageIndex) else { return "" }
        return page.sortedObjects.compactMap(\.textValue).joined(separator: "\n")
    }

    private func extractPageNumber(_ lower: String) -> Int? {
        if let re = try? NSRegularExpression(pattern: #"page\s+(\d+)"#),
           let m = re.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
           let r = Range(m.range(at: 1), in: lower) {
            return Int(lower[r])
        }
        return nil
    }

    private func summarizeLocally(_ text: String) -> String {
        let words = text.split(whereSeparator: \.isWhitespace)
        if words.isEmpty { return "Page is empty." }
        let preview = words.prefix(40).joined(separator: " ")
        return "Page has \(words.count) words. Preview: \(preview)\(words.count > 40 ? "…" : "")"
    }

    private func professionalize(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.replacingOccurrences(of: "  ", with: " ")
        t = t.replacingOccurrences(of: "n't", with: " not")
        t = t.replacingOccurrences(of: "gonna", with: "going to")
        t = t.replacingOccurrences(of: "wanna", with: "want to")
        if let first = t.first {
            t = String(first).uppercased() + t.dropFirst()
        }
        if !t.hasSuffix(".") && !t.hasSuffix("!") && !t.hasSuffix("?") && t.count > 20 {
            t += "."
        }
        return t
    }

    private func basicGrammar(_ text: String) -> String {
        var t = text
        t = t.replacingOccurrences(of: " i ", with: " I ")
        t = t.replacingOccurrences(of: "  ", with: " ")
        return t
    }
}
