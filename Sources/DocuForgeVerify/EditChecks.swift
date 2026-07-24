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

        // ---- Editable format matrix ----
        check("editable txt", await textEditor.isEditableTextFormat(.txt), "")
        check("editable docx", await textEditor.isEditableTextFormat(.docx), "")
        check("not editable pdf as text", await textEditor.isEditableTextFormat(.pdf) == false, "")
    }
}
