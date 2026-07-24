import XCTest
import AppKit
import PDFKit
@testable import DocuForgeCore

final class DocuForgeTests: XCTestCase {
    var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("DocuForgeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Helpers

    private func makeSamplePDF(pages: Int = 3, name: String = "sample.pdf") throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        let doc = PDFDocument()
        for i in 0..<pages {
            let image = NSImage(size: NSSize(width: 400, height: 500))
            image.lockFocus()
            NSColor.white.setFill()
            NSBezierPath.fill(NSRect(x: 0, y: 0, width: 400, height: 500))
            let text = "Page \(i + 1)" as NSString
            text.draw(at: NSPoint(x: 40, y: 240), withAttributes: [
                .font: NSFont.systemFont(ofSize: 32),
                .foregroundColor: NSColor.black
            ])
            image.unlockFocus()
            if let page = PDFPage(image: image) {
                doc.insert(page, at: doc.pageCount)
            }
        }
        XCTAssertTrue(doc.write(to: url))
        return url
    }

    private func makeSamplePNG(name: String = "sample.png") throws -> URL {
        let url = tempDir.appendingPathComponent(name)
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

    // MARK: - Format detection

    func testFormatDetection() throws {
        XCTAssertEqual(DocumentFormat.detect(url: URL(fileURLWithPath: "/tmp/a.PDF")), .pdf)
        XCTAssertEqual(DocumentFormat.detect(url: URL(fileURLWithPath: "/tmp/a.jpeg")), .jpeg)
        XCTAssertEqual(DocumentFormat.detect(url: URL(fileURLWithPath: "/tmp/a.docx")), .docx)
    }

    func testPageRangeParser() throws {
        let ranges = try PageRangeParser.parse("1-2,4", pageCount: 5)
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(ranges[0].start, 1)
        XCTAssertEqual(ranges[0].end, 2)
        XCTAssertEqual(ranges[1].start, 4)
        XCTAssertEqual(ranges[1].end, 4)
    }

    func testPageRangeParserRejectsOutOfBounds() {
        XCTAssertThrowsError(try PageRangeParser.parse("1-99", pageCount: 3))
    }

    // MARK: - PDF ops

    func testMergePDFs() async throws {
        let a = try makeSamplePDF(pages: 2, name: "a.pdf")
        let b = try makeSamplePDF(pages: 1, name: "b.pdf")
        let out = tempDir.appendingPathComponent("merged.pdf")
        let service = PDFService()
        let result = try await service.merge(urls: [a, b], outputURL: out)
        XCTAssertEqual(result.outputURLs.count, 1)
        let merged = try await service.pageCount(at: out)
        XCTAssertEqual(merged, 3)
    }

    func testSplitEveryPage() async throws {
        let pdf = try makeSamplePDF(pages: 3, name: "split.pdf")
        let outDir = tempDir.appendingPathComponent("split-out", isDirectory: true)
        let service = PDFService()
        let result = try await service.split(
            url: pdf,
            mode: .everyPage,
            rangesText: "",
            everyN: 1,
            outputDirectory: outDir
        )
        XCTAssertEqual(result.outputURLs.count, 3)
    }

    func testSplitRanges() async throws {
        let pdf = try makeSamplePDF(pages: 4, name: "ranges.pdf")
        let outDir = tempDir.appendingPathComponent("range-out", isDirectory: true)
        let service = PDFService()
        let result = try await service.split(
            url: pdf,
            mode: .ranges,
            rangesText: "1-2,4",
            everyN: 1,
            outputDirectory: outDir
        )
        XCTAssertEqual(result.outputURLs.count, 2)
        XCTAssertEqual(try await service.pageCount(at: result.outputURLs[0]), 2)
        XCTAssertEqual(try await service.pageCount(at: result.outputURLs[1]), 1)
    }

    func testCompressProducesFile() async throws {
        let pdf = try makeSamplePDF(pages: 2, name: "compress.pdf")
        let out = tempDir.appendingPathComponent("compressed.pdf")
        let service = PDFService()
        let result = try await service.compress(url: pdf, quality: .low, outputURL: out)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
        XCTAssertEqual(result.outputURLs.first, out)
        XCTAssertGreaterThan(try await service.pageCount(at: out), 0)
    }

    func testPasswordProtectAndUnlock() async throws {
        let pdf = try makeSamplePDF(pages: 1, name: "secure.pdf")
        let locked = tempDir.appendingPathComponent("locked.pdf")
        let unlocked = tempDir.appendingPathComponent("unlocked.pdf")
        let service = PDFService()
        _ = try await service.protect(url: pdf, userPassword: "secret", ownerPassword: "secret", outputURL: locked)
        let lockedDoc = PDFDocument(url: locked)
        XCTAssertNotNil(lockedDoc)
        XCTAssertTrue(lockedDoc?.isLocked == true || lockedDoc?.isEncrypted == true)
        _ = try await service.unlock(url: locked, password: "secret", outputURL: unlocked)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unlocked.path))
        let openDoc = PDFDocument(url: unlocked)
        XCTAssertEqual(openDoc?.isLocked, false)
    }

    func testWatermark() async throws {
        let pdf = try makeSamplePDF(pages: 1, name: "wm.pdf")
        let out = tempDir.appendingPathComponent("wm-out.pdf")
        let service = PDFService()
        _ = try await service.watermark(url: pdf, options: WatermarkOptions(text: "TEST"), outputURL: out)
        XCTAssertEqual(try await service.pageCount(at: out), 1)
    }

    func testReorderDelete() async throws {
        let pdf = try makeSamplePDF(pages: 3, name: "reorder.pdf")
        let out = tempDir.appendingPathComponent("reordered.pdf")
        let service = PDFService()
        // Keep page 3, then page 1 (0-based: 2, 0) — drop middle
        _ = try await service.reorderRotateDelete(
            url: pdf,
            orderedIndices: [2, 0],
            rotations: [0: 90],
            outputURL: out
        )
        XCTAssertEqual(try await service.pageCount(at: out), 2)
    }

    func testImagesToPDFAndBack() async throws {
        let png = try makeSamplePNG()
        let pdfOut = tempDir.appendingPathComponent("from-image.pdf")
        let service = PDFService()
        _ = try await service.imagesToPDF(urls: [png], outputURL: pdfOut)
        XCTAssertEqual(try await service.pageCount(at: pdfOut), 1)

        let imgDir = tempDir.appendingPathComponent("pdf-images", isDirectory: true)
        let result = try await service.pdfToImages(url: pdfOut, format: .png, outputDirectory: imgDir)
        XCTAssertEqual(result.outputURLs.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.outputURLs[0].path))
    }

    // MARK: - Image convert

    func testImageConvertPNGToJPEG() async throws {
        let png = try makeSamplePNG()
        let out = tempDir.appendingPathComponent("out.jpg")
        let service = ImageService()
        let result = try await service.convert(url: png, to: .jpeg, outputURL: out)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
        XCTAssertGreaterThan(result.bytesOut, 0)
    }

    // MARK: - Conversion service

    func testConvertTextToPDF() async throws {
        let txt = tempDir.appendingPathComponent("hello.txt")
        try "Hello DocuForge\nLine 2".write(to: txt, atomically: true, encoding: .utf8)
        let outDir = tempDir.appendingPathComponent("conv", isDirectory: true)
        let service = ConversionService()
        let result = try await service.convert(url: txt, to: .pdf, outputDirectory: outDir)
        XCTAssertEqual(result.outputURLs.count, 1)
        XCTAssertEqual(result.outputURLs[0].pathExtension, "pdf")
    }

    func testConvertDOCXTextExtraction() async throws {
        // Minimal DOCX: ZIP with [Content_Types].xml and word/document.xml
        let docx = try makeMinimalDOCX()
        let outDir = tempDir.appendingPathComponent("docx-out", isDirectory: true)
        let service = ConversionService()
        let result = try await service.convert(url: docx, to: .txt, outputDirectory: outDir)
        let text = try String(contentsOf: result.outputURLs[0], encoding: .utf8)
        XCTAssertTrue(text.contains("Hello from DOCX"))
    }

    // MARK: - Minimal DOCX builder

    private func makeMinimalDOCX() throws -> URL {
        let url = tempDir.appendingPathComponent("sample.docx")
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
        let data = try ZipWriter.create(entries: [
            "[Content_Types].xml": Data(contentTypes.utf8),
            "word/document.xml": Data(documentXML.utf8)
        ])
        try data.write(to: url)
        return url
    }
}

/// Minimal ZIP writer (store only) for tests.
enum ZipWriter {
    static func create(entries: [String: Data]) throws -> Data {
        var data = Data()
        var central = Data()
        var offsets: [(name: String, offset: UInt32, size: UInt32, crc: UInt32)] = []

        for (name, payload) in entries {
            let nameData = Data(name.utf8)
            let offset = UInt32(data.count)
            let crc = crc32(payload)
            // local file header
            data.append(contentsOf: u32(0x04034b50))
            data.append(contentsOf: u16(20)) // version
            data.append(contentsOf: u16(0)) // flags
            data.append(contentsOf: u16(0)) // compression store
            data.append(contentsOf: u16(0)) // time
            data.append(contentsOf: u16(0)) // date
            data.append(contentsOf: u32(crc))
            data.append(contentsOf: u32(UInt32(payload.count)))
            data.append(contentsOf: u32(UInt32(payload.count)))
            data.append(contentsOf: u16(UInt16(nameData.count)))
            data.append(contentsOf: u16(0)) // extra
            data.append(nameData)
            data.append(payload)
            offsets.append((name, offset, UInt32(payload.count), crc))
        }

        let centralOffset = UInt32(data.count)
        for entry in offsets {
            let nameData = Data(entry.name.utf8)
            central.append(contentsOf: u32(0x02014b50))
            central.append(contentsOf: u16(20))
            central.append(contentsOf: u16(20))
            central.append(contentsOf: u16(0))
            central.append(contentsOf: u16(0))
            central.append(contentsOf: u16(0))
            central.append(contentsOf: u16(0))
            central.append(contentsOf: u32(entry.crc))
            central.append(contentsOf: u32(entry.size))
            central.append(contentsOf: u32(entry.size))
            central.append(contentsOf: u16(UInt16(nameData.count)))
            central.append(contentsOf: u16(0))
            central.append(contentsOf: u16(0))
            central.append(contentsOf: u16(0))
            central.append(contentsOf: u16(0))
            central.append(contentsOf: u32(0))
            central.append(contentsOf: u32(entry.offset))
            central.append(nameData)
        }
        data.append(central)
        // end of central directory
        data.append(contentsOf: u32(0x06054b50))
        data.append(contentsOf: u16(0))
        data.append(contentsOf: u16(0))
        data.append(contentsOf: u16(UInt16(offsets.count)))
        data.append(contentsOf: u16(UInt16(offsets.count)))
        data.append(contentsOf: u32(UInt32(central.count)))
        data.append(contentsOf: u32(centralOffset))
        data.append(contentsOf: u16(0))
        return data
    }

    private static func u16(_ v: UInt16) -> [UInt8] {
        [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)]
    }
    private static func u32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)]
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                let mask = UInt32(bitPattern: Int32(crc & 1) &* -1)
                crc = (crc >> 1) ^ (0xedb88320 & mask)
            }
        }
        return ~crc
    }
}
