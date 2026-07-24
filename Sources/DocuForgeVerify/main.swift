import Foundation
import AppKit
import PDFKit
import DocuForgeCore

/// Thread-safe failure counter for verification callbacks.
final class FailureCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func add() {
        lock.lock(); value += 1; lock.unlock()
    }
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

@main
struct Verify {
    static func main() async {
        let failures = FailureCounter()
        let check: @Sendable (String, Bool, String) -> Void = { name, ok, detail in
            if ok {
                print("  PASS  \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            } else {
                print("  FAIL  \(name)\(detail.isEmpty ? "" : " — \(detail)")")
                failures.add()
            }
        }

        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocuForgeVerify-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        print("DocuForge verification (multi-page + quality)\n")

        let pdfService = PDFService()
        let conversion = ConversionService()
        let archives = ArchiveService()

        let env = await conversion.environmentSummary()
        print("Engines:")
        for line in env { print("  · \(line)") }
        print("")

        // Detection smoke
        let detections: [(String, DocumentFormat)] = [
            ("a.pdf", .pdf), ("a.docx", .docx), ("a.doc", .doc), ("a.epub", .epub),
            ("a.md", .markdown), ("a.svg", .svg), ("a.tiff", .tiff), ("a.pages", .pages)
        ]
        for (name, expected) in detections {
            let got = DocumentFormat.detect(url: URL(fileURLWithPath: "/tmp/\(name)"))
            check("detect \(name)", got == expected, "got=\(got)")
        }

        // Core PDF multipage ops
        do {
            let a = try makeLabeledPDF(in: temp, pages: 2, name: "a.pdf")
            let b = try makeLabeledPDF(in: temp, pages: 1, name: "b.pdf")
            let out = temp.appendingPathComponent("merged.pdf")
            _ = try await pdfService.merge(urls: [a, b], outputURL: out)
            check("merge PDFs", try await pdfService.pageCount(at: out) == 3, "")
        } catch {
            check("merge PDFs", false, error.localizedDescription)
        }

        // Password
        do {
            let pdf = try makeLabeledPDF(in: temp, pages: 1, name: "sec.pdf")
            let locked = temp.appendingPathComponent("locked.pdf")
            let unlocked = temp.appendingPathComponent("unlocked.pdf")
            _ = try await pdfService.protect(url: pdf, userPassword: "secret", ownerPassword: "secret", outputURL: locked)
            _ = try await pdfService.unlock(url: locked, password: "secret", outputURL: unlocked)
            let openDoc = PDFDocument(url: unlocked)
            check("password", openDoc?.isLocked == false && openDoc?.pageCount == 1, "")
        } catch {
            check("password", false, error.localizedDescription)
        }

        // Single image convert quality path
        do {
            let png = try makePNG(in: temp, name: "s.png")
            let out = temp.appendingPathComponent("s.jpg")
            let r = try await ImageService().convert(url: png, to: .jpeg, outputURL: out, jpegQuality: ImageService.highEncodeQuality)
            check("PNG → JPEG high quality", r.bytesOut > 0, "")
        } catch {
            check("PNG → JPEG high quality", false, error.localizedDescription)
        }

        // DOCX text
        do {
            let docx = try makeMinimalDOCX(in: temp)
            let outDir = temp.appendingPathComponent("docx", isDirectory: true)
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            let r = try await conversion.convert(url: docx, to: .txt, outputDirectory: outDir)
            let text = try String(contentsOf: r.outputURLs[0], encoding: .utf8)
            check("DOCX → TXT", text.contains("Hello from DOCX"), text)
        } catch {
            check("DOCX → TXT", false, error.localizedDescription)
        }

        // ZIP
        do {
            let png = try makePNG(in: temp, name: "z.png")
            let zipURL = temp.appendingPathComponent("p.zip")
            _ = try await archives.createZip(from: [png], outputURL: zipURL)
            let outDir = temp.appendingPathComponent("zout", isDirectory: true)
            let r = try await conversion.convert(url: zipURL, to: .zip, outputDirectory: outDir)
            check("ZIP extract", !r.outputURLs.isEmpty, "")
        } catch {
            check("ZIP extract", false, error.localizedDescription)
        }

        // OCR
        do {
            let image = NSImage(size: NSSize(width: 400, height: 120))
            image.lockFocus()
            NSColor.white.setFill()
            NSBezierPath.fill(NSRect(x: 0, y: 0, width: 400, height: 120))
            ("HELLO OCR" as NSString).draw(at: NSPoint(x: 40, y: 40), withAttributes: [
                .font: NSFont.boldSystemFont(ofSize: 36), .foregroundColor: NSColor.black
            ])
            image.unlockFocus()
            let url = temp.appendingPathComponent("ocr.png")
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let data = rep.representation(using: .png, properties: [:]) else {
                throw DocuForgeError.ocrFailed("encode")
            }
            try data.write(to: url)
            let result = try await OCRService().recognizeText(in: url)
            check("OCR", result.text.uppercased().contains("HELLO") || result.text.uppercased().contains("OCR"), result.text)
        } catch {
            check("OCR", false, error.localizedDescription)
        }

        print("\nMulti-page & quality checks:\n")
        await MultiPageChecks.run(temp: temp, check: check)

        print("\nEdit mode checks:\n")
        await EditChecks.run(temp: temp, check: check)

        let failed = failures.count
        print("\n" + (failed == 0 ? "All checks passed." : "\(failed) check(s) failed."))
        if failed != 0 { exit(1) }
    }

    static func makeLabeledPDF(in dir: URL, pages: Int, name: String) throws -> URL {
        try MultiPageChecks.makeLabeledMultiPagePDF(in: dir, pages: pages, name: name)
    }

    static func makePNG(in dir: URL, name: String) throws -> URL {
        try MultiPageChecks.makeColorPNG(in: dir, name: name, label: "X", color: .systemBlue)
    }

    static func makeMinimalDOCX(in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("sample.docx")
        let work = dir.appendingPathComponent("docx-build", isDirectory: true)
        try FileManager.default.createDirectory(at: work.appendingPathComponent("word"), withIntermediateDirectories: true)
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
        try documentXML.write(to: work.appendingPathComponent("word/document.xml"), atomically: true, encoding: .utf8)
        try contentTypes.write(to: work.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)
        let process = Process()
        process.currentDirectoryURL = work
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-qr", url.path, "word", "[Content_Types].xml"]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw DocuForgeError.conversionFailed("zip") }
        return url
    }
}
