import Foundation
import AppKit
import PDFKit
import DocuForgeCore

@main
struct Verify {
    static func main() async {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if ok {
                print("  PASS  \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            } else {
                print("  FAIL  \(name)\(detail.isEmpty ? "" : " — \(detail)")")
                failures += 1
            }
        }

        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocuForgeVerify-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        print("DocuForge verification\n")

        // Format detection
        check("detect pdf", DocumentFormat.detect(url: URL(fileURLWithPath: "/a.PDF")) == .pdf)
        check("detect jpeg", DocumentFormat.detect(url: URL(fileURLWithPath: "/a.jpeg")) == .jpeg)
        check("detect docx", DocumentFormat.detect(url: URL(fileURLWithPath: "/a.docx")) == .docx)

        // Page ranges
        do {
            let ranges = try PageRangeParser.parse("1-2,4", pageCount: 5)
            check("page ranges", ranges.count == 2 && ranges[0].end == 2 && ranges[1].start == 4)
        } catch {
            check("page ranges", false, error.localizedDescription)
        }
        do {
            _ = try PageRangeParser.parse("1-99", pageCount: 3)
            check("page range bounds", false, "should throw")
        } catch {
            check("page range bounds", true)
        }

        let pdfService = PDFService()
        let imageService = ImageService()
        let conversion = ConversionService()

        func makePDF(pages: Int, name: String) throws -> URL {
            let url = temp.appendingPathComponent(name)
            let doc = PDFDocument()
            for i in 0..<pages {
                let image = NSImage(size: NSSize(width: 400, height: 500))
                image.lockFocus()
                NSColor.white.setFill()
                NSBezierPath.fill(NSRect(x: 0, y: 0, width: 400, height: 500))
                ("Page \(i + 1)" as NSString).draw(at: NSPoint(x: 40, y: 240), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 32),
                    .foregroundColor: NSColor.black
                ])
                image.unlockFocus()
                if let page = PDFPage(image: image) {
                    doc.insert(page, at: doc.pageCount)
                }
            }
            guard doc.write(to: url) else { throw DocuForgeError.pdfOperationFailed("write") }
            return url
        }

        func makePNG(name: String) throws -> URL {
            let url = temp.appendingPathComponent(name)
            let image = NSImage(size: NSSize(width: 200, height: 100))
            image.lockFocus()
            NSColor.systemBlue.setFill()
            NSBezierPath.fill(NSRect(x: 0, y: 0, width: 200, height: 100))
            image.unlockFocus()
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let data = rep.representation(using: .png, properties: [:]) else {
                throw DocuForgeError.conversionFailed("png")
            }
            try data.write(to: url)
            return url
        }

        // Merge
        do {
            let a = try makePDF(pages: 2, name: "a.pdf")
            let b = try makePDF(pages: 1, name: "b.pdf")
            let out = temp.appendingPathComponent("merged.pdf")
            _ = try await pdfService.merge(urls: [a, b], outputURL: out)
            let count = try await pdfService.pageCount(at: out)
            check("merge PDFs", count == 3, "pages=\(count)")
        } catch {
            check("merge PDFs", false, error.localizedDescription)
        }

        // Split
        do {
            let pdf = try makePDF(pages: 3, name: "split.pdf")
            let outDir = temp.appendingPathComponent("split-out", isDirectory: true)
            let result = try await pdfService.split(url: pdf, mode: .everyPage, rangesText: "", everyN: 1, outputDirectory: outDir)
            check("split every page", result.outputURLs.count == 3, "files=\(result.outputURLs.count)")
        } catch {
            check("split every page", false, error.localizedDescription)
        }

        do {
            let pdf = try makePDF(pages: 4, name: "ranges.pdf")
            let outDir = temp.appendingPathComponent("range-out", isDirectory: true)
            let result = try await pdfService.split(url: pdf, mode: .ranges, rangesText: "1-2,4", everyN: 1, outputDirectory: outDir)
            let c0 = try await pdfService.pageCount(at: result.outputURLs[0])
            let c1 = try await pdfService.pageCount(at: result.outputURLs[1])
            check("split ranges", result.outputURLs.count == 2 && c0 == 2 && c1 == 1, "c0=\(c0) c1=\(c1)")
        } catch {
            check("split ranges", false, error.localizedDescription)
        }

        // Compress
        do {
            let pdf = try makePDF(pages: 2, name: "compress.pdf")
            let out = temp.appendingPathComponent("compressed.pdf")
            _ = try await pdfService.compress(url: pdf, quality: .low, outputURL: out)
            let exists = FileManager.default.fileExists(atPath: out.path)
            let pages = try await pdfService.pageCount(at: out)
            check("compress PDF", exists && pages == 2, "pages=\(pages)")
        } catch {
            check("compress PDF", false, error.localizedDescription)
        }

        // Password
        do {
            let pdf = try makePDF(pages: 1, name: "secure.pdf")
            let locked = temp.appendingPathComponent("locked.pdf")
            let unlocked = temp.appendingPathComponent("unlocked.pdf")
            _ = try await pdfService.protect(url: pdf, userPassword: "secret", ownerPassword: "secret", outputURL: locked)
            let lockedDoc = PDFDocument(url: locked)
            let encrypted = lockedDoc?.isEncrypted == true || lockedDoc?.isLocked == true
            _ = try await pdfService.unlock(url: locked, password: "secret", outputURL: unlocked)
            let openDoc = PDFDocument(url: unlocked)
            let openOK = openDoc != nil && openDoc?.isLocked == false && (openDoc?.pageCount ?? 0) == 1
            check("password protect/unlock", encrypted && openOK, "encrypted=\(encrypted) locked=\(String(describing: openDoc?.isLocked)) pages=\(openDoc?.pageCount ?? -1)")
        } catch {
            check("password protect/unlock", false, error.localizedDescription)
        }

        // Watermark
        do {
            let pdf = try makePDF(pages: 1, name: "wm.pdf")
            let out = temp.appendingPathComponent("wm-out.pdf")
            _ = try await pdfService.watermark(url: pdf, options: WatermarkOptions(text: "TEST"), outputURL: out)
            check("watermark", (try await pdfService.pageCount(at: out)) == 1)
        } catch {
            check("watermark", false, error.localizedDescription)
        }

        // Page reorder/delete
        do {
            let pdf = try makePDF(pages: 3, name: "reorder.pdf")
            let out = temp.appendingPathComponent("reordered.pdf")
            _ = try await pdfService.reorderRotateDelete(url: pdf, orderedIndices: [2, 0], rotations: [0: 90], outputURL: out)
            check("page reorder/delete", (try await pdfService.pageCount(at: out)) == 2)
        } catch {
            check("page reorder/delete", false, error.localizedDescription)
        }

        // Images ↔ PDF
        do {
            let png = try makePNG(name: "sample.png")
            let pdfOut = temp.appendingPathComponent("from-image.pdf")
            _ = try await pdfService.imagesToPDF(urls: [png], outputURL: pdfOut)
            let imgDir = temp.appendingPathComponent("pdf-images", isDirectory: true)
            let result = try await pdfService.pdfToImages(url: pdfOut, format: .png, outputDirectory: imgDir)
            check("images ↔ PDF", (try await pdfService.pageCount(at: pdfOut)) == 1 && result.outputURLs.count == 1)
        } catch {
            check("images ↔ PDF", false, error.localizedDescription)
        }

        // Image convert
        do {
            let png = try makePNG(name: "c.png")
            let out = temp.appendingPathComponent("out.jpg")
            let result = try await imageService.convert(url: png, to: .jpeg, outputURL: out)
            check("PNG → JPEG", result.bytesOut > 0 && FileManager.default.fileExists(atPath: out.path))
        } catch {
            check("PNG → JPEG", false, error.localizedDescription)
        }

        // Text → PDF
        do {
            let txt = temp.appendingPathComponent("hello.txt")
            try "Hello DocuForge\nLine 2".write(to: txt, atomically: true, encoding: .utf8)
            let outDir = temp.appendingPathComponent("conv", isDirectory: true)
            let result = try await conversion.convert(url: txt, to: .pdf, outputDirectory: outDir)
            check("TXT → PDF", result.outputURLs.first?.pathExtension == "pdf")
        } catch {
            check("TXT → PDF", false, error.localizedDescription)
        }

        // DOCX text extract
        do {
            let docx = try makeMinimalDOCX(in: temp)
            let outDir = temp.appendingPathComponent("docx-out", isDirectory: true)
            let result = try await conversion.convert(url: docx, to: .txt, outputDirectory: outDir)
            let text = try String(contentsOf: result.outputURLs[0], encoding: .utf8)
            check("DOCX → TXT", text.contains("Hello from DOCX"), "text=\(text.prefix(80))")
        } catch {
            check("DOCX → TXT", false, error.localizedDescription)
        }

        // OCR smoke (image with text) — may be slower
        do {
            let image = NSImage(size: NSSize(width: 400, height: 120))
            image.lockFocus()
            NSColor.white.setFill()
            NSBezierPath.fill(NSRect(x: 0, y: 0, width: 400, height: 120))
            ("HELLO OCR" as NSString).draw(at: NSPoint(x: 40, y: 40), withAttributes: [
                .font: NSFont.boldSystemFont(ofSize: 36),
                .foregroundColor: NSColor.black
            ])
            image.unlockFocus()
            let url = temp.appendingPathComponent("ocr.png")
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let data = rep.representation(using: .png, properties: [:]) else {
                throw DocuForgeError.ocrFailed("encode")
            }
            try data.write(to: url)
            let ocr = OCRService()
            let result = try await ocr.recognizeText(in: url)
            let upper = result.text.uppercased()
            check("OCR Vision", upper.contains("HELLO") || upper.contains("OCR"), "text=\(result.text.prefix(60)) conf=\(result.confidence)")
        } catch {
            check("OCR Vision", false, error.localizedDescription)
        }

        print("\n" + (failures == 0 ? "All checks passed." : "\(failures) check(s) failed."))
        if failures != 0 { exit(1) }
    }

    static func makeMinimalDOCX(in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("sample.docx")
        let documentXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body><w:p><w:r><w:t>Hello from DOCX</w:t></w:r></w:p></w:body>
        </w:document>
        """
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="xml" ContentType="application/xml"/>
          <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
        </Types>
        """
        // Prefer zip CLI for creating the archive (available on macOS)
        let work = dir.appendingPathComponent("docx-build", isDirectory: true)
        try FileManager.default.createDirectory(at: work.appendingPathComponent("word"), withIntermediateDirectories: true)
        try documentXML.write(to: work.appendingPathComponent("word/document.xml"), atomically: true, encoding: .utf8)
        try contentTypes.write(to: work.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)
        let process = Process()
        process.currentDirectoryURL = work
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-qr", url.path, "word", "[Content_Types].xml"]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw DocuForgeError.conversionFailed("zip create failed")
        }
        return url
    }
}
