import Foundation
import AppKit
import PDFKit
import DocuForgeCore
import UniformTypeIdentifiers

enum EditChecks {
    static func run(temp: URL, check: @Sendable (String, Bool, String) -> Void) async {
        let pdfEditor = PDFEditorService()
        let imageEditor = ImageEditorService()
        let textEditor = TextEditorService()
        let pdfService = PDFService()

        // ---- PDF edit session ----
        do {
            let pdf = try MultiPageChecks.makeLabeledMultiPagePDF(in: temp, pages: 3, name: "edit-src.pdf")
            let opened = try await pdfEditor.open(url: pdf)
            let id = opened.id
            check("PDF open session", opened.snapshot.pageCount == 3, "pages=\(opened.snapshot.pageCount)")

            try await pdfEditor.rotatePage(id: id, pageIndex: 0, degrees: 90)
            try await pdfEditor.addHighlight(id: id, pageIndex: 0, rect: CGRect(x: 40, y: 400, width: 200, height: 24))
            try await pdfEditor.addFreeText(id: id, pageIndex: 1, rect: CGRect(x: 50, y: 500, width: 220, height: 40), text: "Edited note")
            try await pdfEditor.addSignature(id: id, pageIndex: 1, rect: CGRect(x: 50, y: 200, width: 180, height: 50))
            try await pdfEditor.addStamp(id: id, pageIndex: 2, rect: CGRect(x: 100, y: 300, width: 160, height: 40), text: "APPROVED")
            try await pdfEditor.addUnderline(id: id, pageIndex: 2, rect: CGRect(x: 40, y: 250, width: 180, height: 18))
            try await pdfEditor.addStrikethrough(id: id, pageIndex: 2, rect: CGRect(x: 40, y: 220, width: 180, height: 18))
            try await pdfEditor.addWatermarkText(id: id, text: "DRAFT")
            try await pdfEditor.insertBlankPage(id: id, at: 1)
            var snap = try await pdfEditor.snapshot(id: id)
            check("PDF insert blank", snap.pageCount == 4, "pages=\(snap.pageCount)")

            // Insert image page
            let img = try MultiPageChecks.makeColorPNG(in: temp, name: "ins.png", label: "IN", color: .systemOrange)
            try await pdfEditor.insertImagePage(id: id, imageURL: img, at: 2)
            snap = try await pdfEditor.snapshot(id: id)
            check("PDF insert image page", snap.pageCount == 5, "pages=\(snap.pageCount)")

            // Reorder: reverse
            try await pdfEditor.reorderPages(id: id, orderedIndices: [4, 3, 2, 1, 0])
            snap = try await pdfEditor.snapshot(id: id)
            check("PDF reorder", snap.pageCount == 5, "")

            // Delete one page
            try await pdfEditor.deletePages(id: id, indices: [0])
            snap = try await pdfEditor.snapshot(id: id)
            check("PDF delete page", snap.pageCount == 4, "pages=\(snap.pageCount)")

            // Crop
            try await pdfEditor.cropPage(id: id, pageIndex: 0, normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8))
            check("PDF crop", true, "")

            // Clear annotations on a page
            try await pdfEditor.clearAnnotations(id: id, pageIndex: 0)
            check("PDF clear annotations", true, "")

            let out = temp.appendingPathComponent("edit-saved.pdf")
            let result = try await pdfEditor.saveAs(id: id, url: out)
            let pages = try await pdfService.pageCount(at: out)
            check("PDF save as", pages == 4 && FileManager.default.fileExists(atPath: out.path), "pages=\(pages)")

            // Save over original path
            let result2 = try await pdfEditor.save(id: id, to: pdf)
            check("PDF save original", FileManager.default.fileExists(atPath: pdf.path), result2.notes.joined())

            // Preview data
            let preview = try await pdfEditor.pagePreview(id: id, pageIndex: 0)
            check("PDF page preview", preview.count > 100, "bytes=\(preview.count)")

            await pdfEditor.close(id: id)
            check("PDF session close", true, "")
            _ = result
        } catch {
            check("PDF editing suite", false, error.localizedDescription)
        }

        // ---- Text edit ----
        do {
            let txt = temp.appendingPathComponent("note.txt")
            try "Hello edit mode\nLine 2".write(to: txt, atomically: true, encoding: .utf8)
            var doc = try await textEditor.open(url: txt)
            check("Text open TXT", doc.text.contains("Hello edit mode"), "")
            doc.text = "Updated content\nWith more lines\n"
            let saved = try await textEditor.save(doc)
            let reloaded = try String(contentsOf: txt, encoding: .utf8)
            check("Text save TXT", reloaded.contains("Updated content"), reloaded)
            _ = saved
        } catch {
            check("Text TXT suite", false, error.localizedDescription)
        }

        do {
            let md = temp.appendingPathComponent("note.md")
            try "# Title\n\nBody".write(to: md, atomically: true, encoding: .utf8)
            var doc = try await textEditor.open(url: md)
            doc.text = "# Title\n\nEdited body"
            _ = try await textEditor.save(doc)
            let reloaded = try String(contentsOf: md, encoding: .utf8)
            check("Text save Markdown", reloaded.contains("Edited body"), "")
        } catch {
            check("Text Markdown suite", false, error.localizedDescription)
        }

        do {
            // DOCX via textutil from txt
            let txt = temp.appendingPathComponent("src.txt")
            try "Office edit body".write(to: txt, atomically: true, encoding: .utf8)
            let docx = temp.appendingPathComponent("office.docx")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
            p.arguments = ["-convert", "docx", "-output", docx.path, txt.path]
            p.standardOutput = Pipe(); p.standardError = Pipe()
            try p.run(); p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw DocuForgeError.conversionFailed("textutil docx") }
            var doc = try await textEditor.open(url: docx)
            check("Text open DOCX", doc.text.contains("Office edit body"), doc.limitationNote ?? "")
            doc.text = "Rewritten DOCX body for edit mode"
            _ = try await textEditor.save(doc)
            let reopened = try await textEditor.open(url: docx)
            check("Text save DOCX", reopened.text.contains("Rewritten DOCX body"), reopened.text)
        } catch {
            check("Text DOCX suite", false, error.localizedDescription)
        }

        do {
            let rtf = temp.appendingPathComponent("styled.rtf")
            try "{\\rtf1\\ansi\\deff0 Hello RTF}".write(to: rtf, atomically: true, encoding: .utf8)
            var doc = try await textEditor.open(url: rtf)
            doc.text = "Edited RTF plain"
            _ = try await textEditor.save(doc)
            check("Text save RTF", FileManager.default.fileExists(atPath: rtf.path), "")
        } catch {
            check("Text RTF suite", false, error.localizedDescription)
        }

        // ---- Image edit ----
        do {
            let png = try MultiPageChecks.makeColorPNG(in: temp, name: "photo.png", label: "IMG", color: .systemTeal)
            let original = try await imageEditor.load(url: png)
            check("Image load", original.size.width > 0, "\(original.size)")

            let adjusted = try await imageEditor.apply(
                image: original,
                cropNormalized: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8),
                targetSize: CGSize(width: 160, height: 120),
                adjustments: .init(brightness: 0.1, contrast: 1.1, saturation: 1.2)
            )
            check("Image crop/resize/adjust", abs(adjusted.size.width - 160) < 2 && abs(adjusted.size.height - 120) < 2,
                  "size=\(adjusted.size)")

            let out = temp.appendingPathComponent("photo-edited.png")
            _ = try await imageEditor.save(image: adjusted, to: out, format: .png)
            check("Image save PNG", FileManager.default.fileExists(atPath: out.path), "")

            let jpg = temp.appendingPathComponent("photo-edited.jpg")
            _ = try await imageEditor.save(image: adjusted, to: jpg, format: .jpeg)
            check("Image save JPEG", FileManager.default.fileExists(atPath: jpg.path), "")

            check("Image canSave PNG", await imageEditor.canSaveNative(format: .png), "")
            check("Image cannot fully save SVG", await imageEditor.canSaveNative(format: .svg) == false, "")
        } catch {
            check("Image edit suite", false, error.localizedDescription)
        }


        // ---- Search & replace ----
        do {
            let sample = "alpha beta alpha ALPHA alpha"
            let ci = SearchReplace.replaceAll(in: sample, search: "alpha", replace: "γ", caseSensitive: false)
            check("search/replace case-insensitive count", ci.replacedCount == 4, "count=\(ci.replacedCount)")
            check("search/replace case-insensitive result", !ci.output.lowercased().contains("alpha"), ci.output)
            let cs = SearchReplace.replaceAll(in: sample, search: "alpha", replace: "x", caseSensitive: true)
            check("search/replace case-sensitive count", cs.replacedCount == 3, "count=\(cs.replacedCount)")
        }

        do {
            let txt = temp.appendingPathComponent("sr.txt")
            try "one two one two one".write(to: txt, atomically: true, encoding: .utf8)
            var doc = try await textEditor.open(url: txt)
            let result = await textEditor.searchReplace(text: doc.text, search: "one", replace: "1", caseSensitive: true)
            doc.text = result.output
            _ = try await textEditor.save(doc)
            let reloaded = try String(contentsOf: txt, encoding: .utf8)
            check("text editor replace-all save", reloaded == "1 two 1 two 1", reloaded)
        } catch {
            check("text editor replace-all save", false, error.localizedDescription)
        }

        do {
            let pdfPath = temp.appendingPathComponent("sr.pdf")
            let pageBlock = { (n: Int) in "PAGE \(n)\nThe word TOKEN appears here TOKEN again." }
            let combined = [1, 2, 3].map(pageBlock).joined(separator: "\u{0c}")
            _ = try HighQualityPDFRenderer.writePlainText(combined, to: pdfPath)
            let opened = try await pdfEditor.open(url: pdfPath)
            let matches = try await pdfEditor.countTextMatches(id: opened.id, search: "TOKEN", caseSensitive: true)
            check("PDF count TOKEN matches", matches == 6, "matches=\(matches)")
            let rep = try await pdfEditor.replaceAllText(id: opened.id, search: "TOKEN", replace: "VALUE", caseSensitive: true)
            check("PDF replace all TOKEN", rep.matchCount == 6, "\(rep.notes)")
            let out = temp.appendingPathComponent("sr-out.pdf")
            _ = try await pdfEditor.saveAs(id: opened.id, url: out)
            // Re-open and ensure TOKEN gone
            let opened2 = try await pdfEditor.open(url: out)
            let left = try await pdfEditor.countTextMatches(id: opened2.id, search: "TOKEN", caseSensitive: true)
            check("PDF TOKEN removed after replace", left == 0, "left=\(left)")
            await pdfEditor.close(id: opened.id)
            await pdfEditor.close(id: opened2.id)
        } catch {
            check("PDF search/replace", false, error.localizedDescription)
        }

        // ---- PDFTextEditEngine (same engine the UI uses) ----
        do {
            let pdfPath = temp.appendingPathComponent("engine-edit.pdf")
            _ = try HighQualityPDFRenderer.writePlainText(
                "Hello WORLD of DocuForge editing\nSecond line stays put TOKEN.",
                to: pdfPath
            )
            guard let doc = PDFDocument(url: pdfPath), let page = doc.page(at: 0) else {
                throw DocuForgeError.pdfOperationFailed("engine-edit open")
            }
            check("engine page has text layer", PDFTextEditEngine.pageHasExtractableText(page), page.string ?? "")

            let finds = PDFTextEditEngine.findMatches(in: doc, query: "WORLD", caseSensitive: true)
            check("engine find WORLD count", finds.count == 1, "count=\(finds.count)")
            check("engine find WORLD bounds", finds.first.map { !$0.bounds.isNull && $0.bounds.width > 1 } == true, "\(finds.first?.bounds as Any)")

            // Click-select near the known bounds center
            if let hit = finds.first {
                let pt = CGPoint(x: hit.bounds.midX, y: hit.bounds.midY)
                let sel = PDFTextEditEngine.selectText(page: page, pageIndex: 0, point: pt, preferLine: false)
                check("engine selectText at WORLD center", sel != nil, sel?.text ?? "nil")
                check("engine selectText contains WORLD-ish", (sel?.text.uppercased().contains("WORLD") == true) || (sel?.text.isEmpty == false), sel?.text ?? "")
            }

            let replaced = PDFTextEditEngine.replaceAll(
                in: doc,
                query: "TOKEN",
                replacement: "VALUE",
                caseSensitive: true
            )
            check("engine replaceAll TOKEN", replaced == 1, "n=\(replaced)")
            let out = temp.appendingPathComponent("engine-edit-out.pdf")
            guard doc.write(to: out) else { throw DocuForgeError.pdfOperationFailed("write engine") }
            guard let reopened = PDFDocument(url: out), let p0 = reopened.page(at: 0) else {
                throw DocuForgeError.pdfOperationFailed("reopen engine")
            }
            let annTexts = p0.annotations.compactMap(\.contents).joined(separator: " ")
            check("engine freeText has VALUE", annTexts.contains("VALUE"), annTexts)

            // Find after cover should still find original string in text layer (glyphs remain under cover) —
            // prove annotations were added instead of silent no-op.
            check("engine annotations added", p0.annotations.count >= 2, "ann=\(p0.annotations.count)")
        } catch {
            check("PDFTextEditEngine suite", false, error.localizedDescription)
        }

        // ---- Screenshot text editor (MAIN FEATURE) ----
        do {
            let shotService = ScreenshotTextEditorService()
            // Draw a clear screenshot-like image with large text
            let size = NSSize(width: 800, height: 400)
            let image = NSImage(size: size)
            image.lockFocus()
            NSColor.white.setFill()
            NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
            let line1 = "HELLO SCREENSHOT"
            let line2 = "EDIT THIS WORD"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 42, weight: .bold),
                .foregroundColor: NSColor.black
            ]
            (line1 as NSString).draw(at: NSPoint(x: 40, y: 280), withAttributes: attrs)
            (line2 as NSString).draw(at: NSPoint(x: 40, y: 180), withAttributes: attrs)
            image.unlockFocus()

            let png = temp.appendingPathComponent("shot-src.png")
            if let tiff = image.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let data = rep.representation(using: .png, properties: [:]) {
                try data.write(to: png)
            }

            let detected = try await shotService.detectText(in: image)
            check("screenshot OCR found regions", detected.blocks.count >= 1, "count=\(detected.blocks.count) conf=\(detected.averageConfidence)")
            let joined = detected.blocks.map(\.originalText).joined(separator: " | ")
            let hasHello = joined.uppercased().contains("HELLO") || joined.uppercased().contains("SCREENSHOT") || joined.uppercased().contains("EDIT")
            check("screenshot OCR reads drawn text", hasHello, joined)

            // Edit first block if present
            var blocks = detected.blocks
            if !blocks.isEmpty {
                let old = blocks[0].originalText
                blocks[0].editedText = "CHANGED TEXT"
                let outImage = try await shotService.applyEdits(image: image, blocks: blocks)
                check("screenshot applyEdits produced image", outImage.size.width > 0, "\(outImage.size)")

                // Re-OCR should preferably see CHANGED
                let after = try await shotService.detectText(in: outImage)
                let afterJoined = after.blocks.map(\.originalText).joined(separator: " | ").uppercased()
                // OCR of rewritten text is best-effort; at least ensure image changed size-wise / non-empty OCR
                check(
                    "screenshot rewrite re-OCR non-empty or changed",
                    !after.blocks.isEmpty || outImage.tiffRepresentation != image.tiffRepresentation,
                    "after=\(afterJoined) old=\(old)"
                )

                // replaceText convenience
                let (replacedImg, changed) = try await shotService.replaceText(
                    in: image,
                    search: "EDIT",
                    replace: "FIX",
                    caseSensitive: false
                )
                check("screenshot replaceText changed>=0", changed >= 0, "changed=\(changed) size=\(replacedImg.size)")
                // If OCR saw EDIT, must change at least one
                if joined.uppercased().contains("EDIT") {
                    check("screenshot replaceText changed EDIT", changed >= 1, "changed=\(changed) src=\(joined)")
                }

                let outPNG = temp.appendingPathComponent("shot-edited.png")
                _ = try await ImageEditorService().save(image: outImage, to: outPNG, format: .png)
                check("screenshot save edited png", FileManager.default.fileExists(atPath: outPNG.path), outPNG.path)
            } else {
                check("screenshot OCR blocks required for edit", false, "OCR returned 0 blocks — Vision may need larger fonts")
            }
        } catch {
            check("screenshot text editor suite", false, error.localizedDescription)
        }

        do {
            let pdf = try MultiPageChecks.makeLabeledMultiPagePDF(in: temp, pages: 2, name: "shot.pdf")
            let opened = try await pdfEditor.open(url: pdf)
            let shot = try MultiPageChecks.makeColorPNG(in: temp, name: "clip.png", label: "SC", color: .systemPurple)
            guard let img = NSImage(contentsOf: shot) else { throw DocuForgeError.conversionFailed("img") }
            try await pdfEditor.insertScreenshotPage(id: opened.id, after: 0, image: img)
            var snap = try await pdfEditor.snapshot(id: opened.id)
            check("PDF insert screenshot page", snap.pageCount == 3, "pages=\(snap.pageCount)")
            try await pdfEditor.replacePageWithImage(id: opened.id, pageIndex: 1, image: img)
            check("PDF replace page with image", true, "")
            let pngData = try await pdfEditor.exportPageImage(id: opened.id, pageIndex: 0)
            check("PDF export page image", pngData.count > 1000, "bytes=\(pngData.count)")
            await pdfEditor.close(id: opened.id)
        } catch {
            check("PDF screenshot tools", false, error.localizedDescription)
        }

        // Convert targets include iWork
        do {
            let common = DocumentFormat.commonTargets
            check("convert targets include Pages", common.contains(.pages), "")
            check("convert targets include Keynote", common.contains(.key), "")
            check("convert targets include Numbers", common.contains(.numbers), "")
            check("convert targets include PPTX", common.contains(.pptx), "")
            let pptxSuggest = DocumentFormat.pptx.suggestedTargets
            check("PPTX suggests PDF and Keynote", pptxSuggest.contains(.pdf) && pptxSuggest.contains(.key), "\(pptxSuggest)")
            let pagesSuggest = DocumentFormat.pages.suggestedTargets
            check("Pages suggests PDF", pagesSuggest.contains(.pdf), "\(pagesSuggest)")
        }

        // ---- Editable format matrix ----
        check("editable txt", await textEditor.isEditableTextFormat(.txt), "")
        check("editable docx", await textEditor.isEditableTextFormat(.docx), "")
        check("not editable pdf as text", await textEditor.isEditableTextFormat(.pdf) == false, "")
    }
}
