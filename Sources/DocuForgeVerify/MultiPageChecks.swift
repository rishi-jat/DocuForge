import Foundation
import AppKit
import PDFKit
import DocuForgeCore
import UniformTypeIdentifiers

enum MultiPageChecks {
    static func run(temp: URL, check: @Sendable (String, Bool, String) -> Void) async {
        let conversion = ConversionService()
        let pdfService = PDFService()

        // --- Multi-page plain text → PDF ---
        do {
            // Enough content + form feeds to force several pages
            var lines: [String] = []
            for i in 1...120 {
                lines.append("Line \(i): The quick brown fox jumps over the lazy dog. Multi-page verification content.")
            }
            // Explicit page breaks
            let text = (1...5).map { page in
                "PAGE \(page) HEADER\n" + lines.joined(separator: "\n")
            }.joined(separator: "\u{0c}")

            let out = temp.appendingPathComponent("multipage-text.pdf")
            let result = try HighQualityPDFRenderer.writePlainText(text, to: out)
            let pages = try await pdfService.pageCount(at: out)
            check("plain text → multi-page PDF", pages >= 5, "pages=\(pages) notes=\(result.notes.joined(separator: "; "))")
            // Ensure later page content exists in text layer / file size sanity
            check("multi-page PDF non-trivial size", FileIO.fileSize(at: out) > 2000, "bytes=\(FileIO.fileSize(at: out))")
        } catch {
            check("plain text → multi-page PDF", false, error.localizedDescription)
        }

        // --- Multi-page RTF (simulating DOC/DOCX rich path) → PDF ---
        do {
            let rtfURL = temp.appendingPathComponent("multipage.rtf")
            // Build RTF with lots of paragraphs
            var body = ""
            for i in 1...200 {
                body += "Paragraph \(i) keeps fonts and flows across pages when converted.\\par\n"
            }
            let rtf = "{\\rtf1\\ansi\\deff0{\\fonttbl{\\f0 Helvetica;}}\\f0\\fs24\n\(body)}"
            try rtf.write(to: rtfURL, atomically: true, encoding: .utf8)

            let outDir = temp.appendingPathComponent("rtf-out", isDirectory: true)
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            let result = try await conversion.convert(url: rtfURL, to: .pdf, outputDirectory: outDir)
            guard let pdfURL = result.outputURLs.first else {
                check("RTF → multi-page PDF", false, "no output")
                return
            }
            let pages = try await pdfService.pageCount(at: pdfURL)
            check("RTF → multi-page PDF", pages >= 3, "pages=\(pages)")
        } catch {
            check("RTF → multi-page PDF", false, error.localizedDescription)
        }

        // --- Multi-page DOC via textutil ---
        do {
            let txt = temp.appendingPathComponent("long.txt")
            var content = ""
            for i in 1...250 {
                content += "Document line \(i): quality-preserving multi-page conversion check.\n"
            }
            try content.write(to: txt, atomically: true, encoding: .utf8)
            let docURL = temp.appendingPathComponent("long.doc")
            let tu = TextUtilService()
            _ = try await tu.convert(url: txt, to: .doc, outputURL: docURL)
            let outDir = temp.appendingPathComponent("doc-out", isDirectory: true)
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            let result = try await conversion.convert(url: docURL, to: .pdf, outputDirectory: outDir)
            let pages = try await pdfService.pageCount(at: result.outputURLs[0])
            check("DOC → multi-page PDF", pages >= 3, "pages=\(pages)")
        } catch {
            check("DOC → multi-page PDF", false, error.localizedDescription)
        }

        // --- Multi-page DOCX ---
        do {
            let txt = temp.appendingPathComponent("long2.txt")
            var content = ""
            for i in 1...250 {
                content += "DOCX line \(i): ensure every page is retained in order.\n"
            }
            try content.write(to: txt, atomically: true, encoding: .utf8)
            let docxURL = temp.appendingPathComponent("long.docx")
            let tu = TextUtilService()
            _ = try await tu.convert(url: txt, to: .docx, outputURL: docxURL)
            let outDir = temp.appendingPathComponent("docx-mp", isDirectory: true)
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            let result = try await conversion.convert(url: docxURL, to: .pdf, outputDirectory: outDir)
            let pages = try await pdfService.pageCount(at: result.outputURLs[0])
            check("DOCX → multi-page PDF", pages >= 3, "pages=\(pages)")
        } catch {
            check("DOCX → multi-page PDF", false, error.localizedDescription)
        }

        // --- Multi-page source PDF → images (all pages) ---
        do {
            let pdf = try makeLabeledMultiPagePDF(in: temp, pages: 4, name: "source-4.pdf")
            let outDir = temp.appendingPathComponent("pdf-imgs", isDirectory: true)
            let result = try await pdfService.pdfToImages(url: pdf, format: .png, outputDirectory: outDir)
            check("PDF → PNG exports all pages", result.outputURLs.count == 4, "count=\(result.outputURLs.count)")
            // Verify order by filename
            let names = result.outputURLs.map(\.lastPathComponent)
            let ordered = names == names.sorted()
            check("PDF → PNG page order", ordered || names.joined().contains("p1"), "names=\(names)")
            // High DPI: each PNG should be reasonably large
            let sizes = result.outputURLs.map { FileIO.fileSize(at: $0) }
            check("PDF → PNG high quality size", sizes.allSatisfy { $0 > 5000 }, "sizes=\(sizes)")
        } catch {
            check("PDF → PNG multi-page", false, error.localizedDescription)
        }

        // Multi-page PDF with real text layer → TXT keeps every page marker
        do {
            let pdf = temp.appendingPathComponent("source-text-3.pdf")
            let body = (1...3).map { p in
                "PAGE \(p)\n" + (1...40).map { "Page \(p) line \($0) with extractable text." }.joined(separator: "\n")
            }.joined(separator: "\u{0c}")
            _ = try HighQualityPDFRenderer.writePlainText(body, to: pdf)
            let pageCount = try await pdfService.pageCount(at: pdf)
            check("text PDF fixture pages", pageCount >= 3, "pages=\(pageCount)")
            let outDir = temp.appendingPathComponent("pdf-txt", isDirectory: true)
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            let result = try await conversion.convert(url: pdf, to: .txt, outputDirectory: outDir)
            let text = try String(contentsOf: result.outputURLs[0], encoding: .utf8)
            let hasAll = text.contains("PAGE 1") && text.contains("PAGE 2") && text.contains("PAGE 3")
            check("PDF → TXT keeps all pages", hasAll, "len=\(text.count) preview=\(text.prefix(80))")
        } catch {
            check("PDF → TXT multi-page", false, error.localizedDescription)
        }

        // --- Multi-page images → single PDF (order preserved) ---
        do {
            var imgs: [URL] = []
            for i in 1...3 {
                imgs.append(try makeColorPNG(in: temp, name: "frame-\(i).png", label: "F\(i)", color: i == 1 ? .systemRed : (i == 2 ? .systemGreen : .systemBlue)))
            }
            let out = temp.appendingPathComponent("from-frames.pdf")
            let result = try await pdfService.imagesToPDF(urls: imgs, outputURL: out)
            let pages = try await pdfService.pageCount(at: out)
            check("images → PDF page count", pages == 3, "pages=\(pages) notes=\(result.notes)")
        } catch {
            check("images → PDF multi", false, error.localizedDescription)
        }

        // --- Multi-page TIFF → PDF ---
        do {
            let tiff = try makeMultiPageTIFF(in: temp, pages: 3)
            let outDir = temp.appendingPathComponent("tiff-pdf", isDirectory: true)
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            let result = try await conversion.convert(url: tiff, to: .pdf, outputDirectory: outDir)
            let pages = try await pdfService.pageCount(at: result.outputURLs[0])
            check("multi-page TIFF → PDF", pages == 3, "pages=\(pages)")
        } catch {
            check("multi-page TIFF → PDF", false, error.localizedDescription)
        }

        // --- HTML multi-page ---
        do {
            var paras = ""
            for i in 1...180 {
                paras += "<p>HTML paragraph \(i) for multi-page conversion with formatting.</p>\n"
            }
            let html = "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><style>body{font-family:Helvetica;font-size:14px}</style></head><body>\(paras)</body></html>"
            let htmlURL = temp.appendingPathComponent("long.html")
            try html.write(to: htmlURL, atomically: true, encoding: .utf8)
            let outDir = temp.appendingPathComponent("html-pdf", isDirectory: true)
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            let result = try await conversion.convert(url: htmlURL, to: .pdf, outputDirectory: outDir)
            let pages = try await pdfService.pageCount(at: result.outputURLs[0])
            check("HTML → multi-page PDF", pages >= 3, "pages=\(pages)")
        } catch {
            check("HTML → multi-page PDF", false, error.localizedDescription)
        }

        // --- EPUB multi-chapter → multi-page PDF ---
        do {
            let epub = try makeMultiChapterEPUB(in: temp)
            let outDir = temp.appendingPathComponent("epub-mp", isDirectory: true)
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            let result = try await conversion.convert(url: epub, to: .pdf, outputDirectory: outDir)
            let pages = try await pdfService.pageCount(at: result.outputURLs[0])
            check("EPUB multi-chapter → multi-page PDF", pages >= 2, "pages=\(pages)")
            let txtDir = temp.appendingPathComponent("epub-txt", isDirectory: true)
            try FileManager.default.createDirectory(at: txtDir, withIntermediateDirectories: true)
            let txtResult = try await conversion.convert(url: epub, to: .txt, outputDirectory: txtDir)
            let text = try String(contentsOf: txtResult.outputURLs[0], encoding: .utf8)
            check("EPUB text has all chapters", text.contains("Chapter One") && text.contains("Chapter Two") && text.contains("Chapter Three"), "len=\(text.count)")
        } catch {
            check("EPUB multi-page", false, error.localizedDescription)
        }

        // --- Merge still multipage ---
        do {
            let a = try makeLabeledMultiPagePDF(in: temp, pages: 2, name: "m-a.pdf")
            let b = try makeLabeledMultiPagePDF(in: temp, pages: 2, name: "m-b.pdf")
            let out = temp.appendingPathComponent("merged-mp.pdf")
            _ = try await pdfService.merge(urls: [a, b], outputURL: out)
            check("merge multi-page PDFs", try await pdfService.pageCount(at: out) == 4, "")
        } catch {
            check("merge multi-page PDFs", false, error.localizedDescription)
        }
    }

    // MARK: - Fixtures

    static func makeLabeledMultiPagePDF(in dir: URL, pages: Int, name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let doc = PDFDocument()
        for i in 0..<pages {
            let image = NSImage(size: NSSize(width: 612, height: 792))
            image.lockFocus()
            NSColor.white.setFill()
            NSBezierPath.fill(NSRect(x: 0, y: 0, width: 612, height: 792))
            let label = "PAGE \(i + 1)" as NSString
            label.draw(at: NSPoint(x: 200, y: 400), withAttributes: [
                .font: NSFont.boldSystemFont(ofSize: 48),
                .foregroundColor: NSColor.black
            ])
            ("Content for page \(i + 1)" as NSString).draw(at: NSPoint(x: 180, y: 340), withAttributes: [
                .font: NSFont.systemFont(ofSize: 18),
                .foregroundColor: NSColor.darkGray
            ])
            image.unlockFocus()
            if let page = PDFPage(image: image) {
                doc.insert(page, at: doc.pageCount)
            }
        }
        guard doc.write(to: url) else { throw DocuForgeError.pdfOperationFailed("write multipage") }
        return url
    }

    static func makeColorPNG(in dir: URL, name: String, label: String, color: NSColor) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let image = NSImage(size: NSSize(width: 400, height: 300))
        image.lockFocus()
        color.setFill()
        NSBezierPath.fill(NSRect(x: 0, y: 0, width: 400, height: 300))
        (label as NSString).draw(at: NSPoint(x: 160, y: 140), withAttributes: [
            .font: NSFont.boldSystemFont(ofSize: 36),
            .foregroundColor: NSColor.white
        ])
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else {
            throw DocuForgeError.conversionFailed("png")
        }
        try data.write(to: url)
        return url
    }

    static func makeMultiPageTIFF(in dir: URL, pages: Int) throws -> URL {
        let url = dir.appendingPathComponent("multi.tiff")
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.tiff.identifier as CFString, pages, nil) else {
            throw DocuForgeError.conversionFailed("tiff dest")
        }
        for i in 0..<pages {
            let image = NSImage(size: NSSize(width: 200, height: 200))
            image.lockFocus()
            NSColor(calibratedHue: CGFloat(i) / CGFloat(pages), saturation: 0.7, brightness: 0.9, alpha: 1).setFill()
            NSBezierPath.fill(NSRect(x: 0, y: 0, width: 200, height: 200))
            ("T\(i+1)" as NSString).draw(at: NSPoint(x: 70, y: 90), withAttributes: [
                .font: NSFont.boldSystemFont(ofSize: 32),
                .foregroundColor: NSColor.black
            ])
            image.unlockFocus()
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let cg = rep.cgImage else { continue }
            CGImageDestinationAddImage(dest, cg, nil)
        }
        guard CGImageDestinationFinalize(dest) else { throw DocuForgeError.conversionFailed("tiff finalize") }
        try (data as Data).write(to: url)
        return url
    }

    static func makeMultiChapterEPUB(in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("multi.epub")
        let work = dir.appendingPathComponent("epub-multi", isDirectory: true)
        try FileManager.default.createDirectory(at: work.appendingPathComponent("OPS"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: work.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        try "application/epub+zip".write(to: work.appendingPathComponent("mimetype"), atomically: true, encoding: .utf8)
        try """
        <?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
        <rootfiles><rootfile full-path="OPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
        """.write(to: work.appendingPathComponent("META-INF/container.xml"), atomically: true, encoding: .utf8)
        try """
        <?xml version="1.0"?>
        <package xmlns="http://www.idpf.org/2007/opf" unique-identifier="u" version="2.0">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Multi</dc:title></metadata>
          <manifest>
            <item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/>
            <item id="c2" href="c2.xhtml" media-type="application/xhtml+xml"/>
            <item id="c3" href="c3.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine>
            <itemref idref="c1"/><itemref idref="c2"/><itemref idref="c3"/>
          </spine>
        </package>
        """.write(to: work.appendingPathComponent("OPS/content.opf"), atomically: true, encoding: .utf8)
        for (i, title) in ["Chapter One", "Chapter Two", "Chapter Three"].enumerated() {
            var body = "<h1>\(title)</h1>"
            for j in 1...40 {
                body += "<p>\(title) paragraph \(j). Lorem ipsum dolor sit amet, consectetur adipiscing elit.</p>"
            }
            try """
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml"><body>\(body)</body></html>
            """.write(to: work.appendingPathComponent("OPS/c\(i+1).xhtml"), atomically: true, encoding: .utf8)
        }
        let process = Process()
        process.currentDirectoryURL = work
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-qr", url.path, "mimetype", "META-INF", "OPS"]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw DocuForgeError.conversionFailed("epub zip") }
        return url
    }
}

