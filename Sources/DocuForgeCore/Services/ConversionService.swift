import Foundation
import AppKit
import PDFKit
import CoreText
import CoreGraphics

/// High-level format conversion orchestrating native tools and optional helpers.
public actor ConversionService {
    private let pdf = PDFService()
    private let images = ImageService()
    private let textUtil = TextUtilService()
    private let iwork = IWorkAutomationService()
    private let quickLook = QuickLookService()
    private let libreOffice = LibreOfficeService()
    private let epub = EPUBService()
    private let archives = ArchiveService()

    public init() {}

    // MARK: - Environment

    public func environmentSummary() async -> [String] {
        var lines: [String] = []
        lines.append("textutil: \(await textUtil.isAvailable() ? "available" : "missing")")
        lines.append("Pages: \(await iwork.isInstalled(.pages) ? "installed" : "not installed")")
        lines.append("Keynote: \(await iwork.isInstalled(.keynote) ? "installed" : "not installed")")
        lines.append("Numbers: \(await iwork.isInstalled(.numbers) ? "installed" : "not installed")")
        lines.append("LibreOffice: \(await libreOffice.isAvailable ? "installed" : "not installed")")
        lines.append("Quick Look: \(await quickLook.isAvailable() ? "available" : "missing")")
        return lines
    }

    // MARK: - Convert

    public func convert(
        url: URL,
        to target: DocumentFormat,
        outputDirectory: URL
    ) async throws -> ProcessingResult {
        let source = DocumentFormat.detect(url: url)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let base = url.deletingPathExtension().lastPathComponent

        if source == .unknown {
            // Try Quick Look / LibreOffice as last-chance decoders
            return try await fallbackUnknown(url: url, target: target, outputDirectory: outputDirectory)
        }

        // Same format → copy
        if source == target {
            return try copyFile(url: url, outputDirectory: outputDirectory)
        }

        // High-fidelity iWork import/export when it clearly improves layout (Office ↔ iWork / PDF).
        if let result = try await tryIWorkHighFidelity(
            url: url,
            source: source,
            target: target,
            outputDirectory: outputDirectory
        ) {
            return result
        }

        // Archives
        if source.isArchive {
            if target == .zip && source != .zip {
                // re-pack not always meaningful — extract then zip contents
                let extractDir = outputDirectory.appendingPathComponent("\(base)-extracted", isDirectory: true)
                let extracted = try await archives.extract(url: url, format: source, outputDirectory: extractDir)
                let zipOut = outputDirectory.appendingPathComponent("\(base).zip")
                return try await archives.createZip(from: extracted.outputURLs, outputURL: zipOut)
            }
            // Default: extract
            let extractDir = outputDirectory.appendingPathComponent("\(base)-extracted", isDirectory: true)
            return try await archives.extract(url: url, format: source, outputDirectory: extractDir)
        }

        // Images → image / PDF (preserve every frame of multi-page TIFF/etc.)
        if source.isImage {
            if target.isImage {
                let frames = try await images.loadAllFrames(url: url)
                if frames.count > 1, target != .tiff {
                    // Export one high-quality file per frame, in order.
                    return try await images.convertAllFrames(
                        url: url,
                        to: target,
                        outputDirectory: outputDirectory,
                        jpegQuality: ImageService.highEncodeQuality
                    )
                }
                let out = outputDirectory.appendingPathComponent("\(base).\(target.pathExtension)")
                return try await images.convert(
                    url: url,
                    to: target,
                    outputURL: out,
                    jpegQuality: ImageService.highEncodeQuality
                )
            }
            if target == .pdf {
                let out = outputDirectory.appendingPathComponent("\(base).pdf")
                return try await pdf.imagesToPDF(urls: [url], outputURL: out)
            }
        }

        // PDF paths
        if source == .pdf {
            if target.isImage {
                return try await pdf.pdfToImages(url: url, format: target, outputDirectory: outputDirectory)
            }
            if target == .txt {
                return try await pdfToPlainText(url: url, outputDirectory: outputDirectory)
            }
            if target == .html {
                return try await pdfToHTML(url: url, outputDirectory: outputDirectory)
            }
            if target.isTextUtilFormat {
                // PDF → text → textutil format
                let txtResult = try await pdfToPlainText(url: url, outputDirectory: outputDirectory)
                guard let txtURL = txtResult.outputURLs.first else {
                    throw DocuForgeError.conversionFailed("PDF text extraction produced no file.")
                }
                let out = outputDirectory.appendingPathComponent("\(base).\(target.pathExtension)")
                var result = try await textUtil.convert(url: txtURL, to: target, outputURL: out)
                return ProcessingResult(
                    outputURLs: result.outputURLs,
                    bytesIn: FileIO.fileSize(at: url),
                    bytesOut: result.bytesOut,
                    notes: ["PDF text extracted then converted with textutil."] + result.notes
                )
            }
            if await libreOffice.isAvailable {
                return try await libreOffice.convert(url: url, to: target, outputDirectory: outputDirectory)
            }
        }

        // Markdown
        if source == .markdown {
            return try await convertMarkdown(url: url, target: target, outputDirectory: outputDirectory)
        }

        // textutil matrix (doc/docx/odt/rtf/html/txt/webarchive)
        if source.isTextUtilFormat, target.isTextUtilFormat, await textUtil.isAvailable() {
            let out = outputDirectory.appendingPathComponent("\(base).\(target.pathExtension)")
            return try await textUtil.convert(url: url, to: target, outputURL: out)
        }
        if source.isTextUtilFormat, target == .pdf {
            // Prefer rich intermediates (RTF/HTML) so fonts/styles survive, then multi-page PDF.
            if source == .html || source == .rtf || source == .rtfd {
                return try richTextToPDF(url: url, source: source, outputDirectory: outputDirectory, preferredBase: base)
            }
            if await textUtil.isAvailable() {
                // RTF preserves more formatting than plain text for DOC/DOCX/ODT.
                let richExt = (source == .html) ? "html" : "rtf"
                let richFormat: DocumentFormat = richExt == "html" ? .html : .rtf
                let tmp = FileIO.temporaryURL(prefix: "tu-rich", ext: richExt)
                defer { try? FileManager.default.removeItem(at: tmp) }
                do {
                    _ = try await textUtil.convert(url: url, to: richFormat, outputURL: tmp)
                    return try richTextToPDF(
                        url: tmp,
                        source: richFormat,
                        outputDirectory: outputDirectory,
                        preferredBase: base
                    )
                } catch {
                    // Fall back to plain text multi-page PDF if rich conversion fails.
                    let tmpTxt = FileIO.temporaryURL(prefix: "tu", ext: "txt")
                    defer { try? FileManager.default.removeItem(at: tmpTxt) }
                    _ = try await textUtil.convert(url: url, to: .txt, outputURL: tmpTxt)
                    let text = try String(contentsOf: tmpTxt, encoding: .utf8)
                    let out = outputDirectory.appendingPathComponent("\(base).pdf")
                    var result = try HighQualityPDFRenderer.writePlainText(
                        text,
                        to: out,
                        bytesIn: FileIO.fileSize(at: url)
                    )
                    return ProcessingResult(
                        outputURLs: result.outputURLs,
                        bytesIn: result.bytesIn,
                        bytesOut: result.bytesOut,
                        notes: ["Converted via textutil text → multi-page PDF."] + result.notes
                    )
                }
            }
        }
        if source.isTextUtilFormat, target == .markdown {
            let tmp = FileIO.temporaryURL(prefix: "tu", ext: "txt")
            defer { try? FileManager.default.removeItem(at: tmp) }
            if await textUtil.isAvailable() {
                _ = try await textUtil.convert(url: url, to: .txt, outputURL: tmp)
            } else {
                try Data(contentsOf: url).write(to: tmp)
            }
            let text = try String(contentsOf: tmp, encoding: .utf8)
            let out = outputDirectory.appendingPathComponent("\(base).md")
            try text.write(to: out, atomically: true, encoding: .utf8)
            return ProcessingResult(outputURLs: [out], bytesIn: FileIO.fileSize(at: url), bytesOut: FileIO.fileSize(at: out))
        }

        // CSV / text-like
        if source.isTextLike || source == .txt {
            return try convertTextLike(url: url, source: source, target: target, outputDirectory: outputDirectory)
        }

        // EPUB
        if source == .epub {
            return try await epub.convert(url: url, to: target, outputDirectory: outputDirectory)
        }

        // iWork: automation → embedded preview → Quick Look
        if source.isIWork {
            return try await convertIWork(url: url, source: source, target: target, outputDirectory: outputDirectory)
        }

        // Office Open XML text path + LO
        if source.isOfficeOpenXML {
            return try await convertOffice(url: url, source: source, target: target, outputDirectory: outputDirectory)
        }

        // OpenDocument (ODT may already be handled by textutil; ODP/ODS)
        if source.isOpenDocument {
            return try await convertOpenDocument(url: url, source: source, target: target, outputDirectory: outputDirectory)
        }

        // Legacy PPT / XLS
        if source.isLegacyOffice {
            return try await convertLegacyOffice(url: url, source: source, target: target, outputDirectory: outputDirectory)
        }

        // LibreOffice catch-all
        if await libreOffice.isAvailable {
            do {
                return try await libreOffice.convert(url: url, to: target, outputDirectory: outputDirectory)
            } catch {
                // fall through
            }
        }

        // Quick Look preview as last resort for image/pdf targets
        if target.isImage || target == .pdf {
            return try await quickLookFallback(url: url, target: target, outputDirectory: outputDirectory)
        }

        throw DocuForgeError.conversionFailed(unsupportedMessage(source: source, target: target))
    }

    // MARK: - Paths

    /// Prefer iWork automation only when it is likely to succeed quickly:
    /// - exporting *to* Pages/Keynote/Numbers, or
    /// - converting presentations to PDF while Keynote is already running.
    /// Word-processing → PDF stays on textutil/native so offline use is always reliable.
    private func tryIWorkHighFidelity(
        url: URL,
        source: DocumentFormat,
        target: DocumentFormat,
        outputDirectory: URL
    ) async throws -> ProcessingResult? {
        if source.isIWork { return nil }

        func attempt(_ app: IWorkAutomationService.AppKind, to target: DocumentFormat) async -> ProcessingResult? {
            guard await iwork.isInstalled(app) else { return nil }
            do {
                return try await iwork.importAndExport(url: url, using: app, to: target, outputDirectory: outputDirectory)
            } catch {
                return nil
            }
        }

        // Explicit export TO iWork formats (user picked Pages/Keynote/Numbers in Convert).
        if target == .pages, let r = await attempt(.pages, to: .pages) { return r }
        if target == .key, let r = await attempt(.keynote, to: .key) { return r }
        if target == .numbers, let r = await attempt(.numbers, to: .numbers) { return r }

        // Optional high-fidelity presentation → PDF only if Keynote is already running
        // (avoids cold-launch hangs and permission dialogs during batch/offline use).
        if target == .pdf, [.pptx, .ppt, .odp].contains(source), await iwork.isInstalled(.keynote) {
            if isAppRunning(named: "Keynote"), let r = await attempt(.keynote, to: .pdf) {
                return r
            }
        }
        return nil
    }

    private func isAppRunning(named name: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.localizedName == name || ($0.bundleIdentifier?.contains(name) ?? false)
        }
    }

    private func copyFile(url: URL, outputDirectory: URL) throws -> ProcessingResult {
        let out = outputDirectory.appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: out.path) {
            try FileManager.default.removeItem(at: out)
        }
        try FileManager.default.copyItem(at: url, to: out)
        return ProcessingResult(
            outputURLs: [out],
            bytesIn: FileIO.fileSize(at: url),
            bytesOut: FileIO.fileSize(at: out),
            notes: ["Copied without conversion."]
        )
    }

    private func pdfToPlainText(url: URL, outputDirectory: URL) async throws -> ProcessingResult {
        guard let doc = PDFDocument(url: url) else {
            throw DocuForgeError.pdfOperationFailed("Could not open PDF.")
        }
        var text = ""
        for i in 0..<doc.pageCount {
            if let page = doc.page(at: i), let s = page.string {
                text += s
                text += "\n\n"
            }
        }
        let out = outputDirectory.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".txt")
        try text.write(to: out, atomically: true, encoding: .utf8)
        var notes: [String] = []
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            notes.append("No embedded text found. Use the OCR tool for scanned PDFs.")
        }
        return ProcessingResult(
            outputURLs: [out],
            bytesIn: FileIO.fileSize(at: url),
            bytesOut: FileIO.fileSize(at: out),
            notes: notes
        )
    }

    private func pdfToHTML(url: URL, outputDirectory: URL) async throws -> ProcessingResult {
        let textResult = try await pdfToPlainText(url: url, outputDirectory: outputDirectory)
        guard let txt = textResult.outputURLs.first else {
            throw DocuForgeError.conversionFailed("No text for HTML.")
        }
        let text = try String(contentsOf: txt, encoding: .utf8)
        let base = url.deletingPathExtension().lastPathComponent
        let out = outputDirectory.appendingPathComponent("\(base).html")
        let escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let html = "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>\(base)</title></head><body><pre>\(escaped)</pre></body></html>"
        try html.write(to: out, atomically: true, encoding: .utf8)
        return ProcessingResult(
            outputURLs: [out],
            bytesIn: FileIO.fileSize(at: url),
            bytesOut: FileIO.fileSize(at: out),
            notes: ["PDF text embedded in a simple HTML wrapper."]
        )
    }

    private func convertTextLike(
        url: URL,
        source: DocumentFormat,
        target: DocumentFormat,
        outputDirectory: URL
    ) throws -> ProcessingResult {
        let data = try Data(contentsOf: url)
        let text: String

        switch source {
        case .txt, .csv, .markdown:
            text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
                ?? ""
        case .html:
            if let attr = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
                documentAttributes: nil
            ) {
                text = attr.string
            } else {
                text = String(data: data, encoding: .utf8) ?? ""
            }
        case .rtf:
            if let attr = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
            ) {
                text = attr.string
            } else {
                text = String(data: data, encoding: .utf8) ?? ""
            }
        default:
            text = String(data: data, encoding: .utf8) ?? ""
        }

        let base = url.deletingPathExtension().lastPathComponent
        switch target {
        case .txt, .markdown, .csv:
            let out = outputDirectory.appendingPathComponent("\(base).\(target.pathExtension)")
            try text.write(to: out, atomically: true, encoding: .utf8)
            return ProcessingResult(outputURLs: [out], bytesIn: FileIO.fileSize(at: url), bytesOut: FileIO.fileSize(at: out))
        case .html:
            let out = outputDirectory.appendingPathComponent("\(base).html")
            let body = source == .markdown ? basicMarkdownToHTML(text) : "<pre>\(htmlEscape(text))</pre>"
            let html = "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>\(base)</title></head><body>\(body)</body></html>"
            try html.write(to: out, atomically: true, encoding: .utf8)
            return ProcessingResult(outputURLs: [out], bytesIn: FileIO.fileSize(at: url), bytesOut: FileIO.fileSize(at: out))
        case .pdf:
            let out = outputDirectory.appendingPathComponent("\(base).pdf")
            return try HighQualityPDFRenderer.writePlainText(
                text,
                to: out,
                bytesIn: FileIO.fileSize(at: url)
            )
        case .rtf, .docx, .doc, .odt:
            // Write text temp then textutil
            let tmp = FileIO.temporaryURL(prefix: "txt", ext: "txt")
            try text.write(to: tmp, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let out = outputDirectory.appendingPathComponent("\(base).\(target.pathExtension)")
            // Can't call actor method from sync - use process directly
            return try textUtilSync(url: tmp, to: target, outputURL: out, bytesIn: FileIO.fileSize(at: url))
        default:
            throw DocuForgeError.conversionFailed("Unsupported text conversion to \(target.displayName).")
        }
    }

    private func convertMarkdown(
        url: URL,
        target: DocumentFormat,
        outputDirectory: URL
    ) async throws -> ProcessingResult {
        let md = try String(contentsOf: url, encoding: .utf8)
        let base = url.deletingPathExtension().lastPathComponent
        switch target {
        case .txt:
            let out = outputDirectory.appendingPathComponent("\(base).txt")
            try md.write(to: out, atomically: true, encoding: .utf8)
            return ProcessingResult(outputURLs: [out], bytesIn: FileIO.fileSize(at: url), bytesOut: FileIO.fileSize(at: out))
        case .html:
            let out = outputDirectory.appendingPathComponent("\(base).html")
            let html = "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>\(base)</title></head><body>\(basicMarkdownToHTML(md))</body></html>"
            try html.write(to: out, atomically: true, encoding: .utf8)
            return ProcessingResult(
                outputURLs: [out],
                bytesIn: FileIO.fileSize(at: url),
                bytesOut: FileIO.fileSize(at: out),
                notes: ["Markdown converted with a lightweight built-in renderer."]
            )
        case .pdf:
            // Render via HTML attributed string to keep simple styles across pages.
            let html = "<!DOCTYPE html><html><head><meta charset=\"utf-8\"></head><body>\(basicMarkdownToHTML(md))</body></html>"
            let tmp = FileIO.temporaryURL(prefix: "md", ext: "html")
            try html.write(to: tmp, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: tmp) }
            return try richTextToPDF(
                url: tmp,
                source: .html,
                outputDirectory: outputDirectory,
                preferredBase: base
            )
        case .docx, .rtf, .doc, .odt:
            let tmp = FileIO.temporaryURL(prefix: "md", ext: "txt")
            try md.write(to: tmp, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let out = outputDirectory.appendingPathComponent("\(base).\(target.pathExtension)")
            return try await textUtil.convert(url: tmp, to: target, outputURL: out)
        default:
            throw DocuForgeError.conversionFailed("Markdown converts to TXT, HTML, PDF, or textutil document formats.")
        }
    }

    private func convertOffice(
        url: URL,
        source: DocumentFormat,
        target: DocumentFormat,
        outputDirectory: URL
    ) async throws -> ProcessingResult {
        // Prefer textutil for DOCX when target is textutil format (better structure than raw XML)
        if source == .docx, target.isTextUtilFormat, await textUtil.isAvailable() {
            let out = outputDirectory.appendingPathComponent(
                url.deletingPathExtension().lastPathComponent + ".\(target.pathExtension)"
            )
            return try await textUtil.convert(url: url, to: target, outputURL: out)
        }
        if source == .docx, target == .pdf, await textUtil.isAvailable() {
            let tmp = FileIO.temporaryURL(prefix: "docx", ext: "rtf")
            defer { try? FileManager.default.removeItem(at: tmp) }
            _ = try await textUtil.convert(url: url, to: .rtf, outputURL: tmp)
            return try richTextToPDF(
                url: tmp,
                source: .rtf,
                outputDirectory: outputDirectory,
                preferredBase: url.deletingPathExtension().lastPathComponent
            )
        }

        // LibreOffice for high fidelity when available
        if await libreOffice.isAvailable {
            do {
                return try await libreOffice.convert(url: url, to: target, outputDirectory: outputDirectory)
            } catch {
                // fall back to text extract
            }
        }

        // PPTX/XLSX text extract
        let formatForXML: DocumentFormat = source
        if source.isOfficeOpenXML {
            let text = try OfficeOpenXML.extractText(from: url, format: formatForXML)
            let base = url.deletingPathExtension().lastPathComponent
            switch target {
            case .txt:
                let out = outputDirectory.appendingPathComponent(base + ".txt")
                try text.write(to: out, atomically: true, encoding: .utf8)
                return ProcessingResult(
                    outputURLs: [out],
                    bytesIn: FileIO.fileSize(at: url),
                    bytesOut: FileIO.fileSize(at: out),
                    notes: ["Extracted text from \(source.displayName). Layout and images are not preserved."]
                )
            case .pdf:
                let out = outputDirectory.appendingPathComponent(base + ".pdf")
                let result = try HighQualityPDFRenderer.writePlainText(
                    text,
                    to: out,
                    bytesIn: FileIO.fileSize(at: url)
                )
                return ProcessingResult(
                    outputURLs: result.outputURLs,
                    bytesIn: FileIO.fileSize(at: url),
                    bytesOut: result.bytesOut,
                    notes: ["Converted \(source.displayName) text to multi-page PDF. Complex layout is flattened."] + result.notes
                )
            case .html:
                let out = outputDirectory.appendingPathComponent(base + ".html")
                let html = "<!DOCTYPE html><html><head><meta charset=\"utf-8\"></head><body><pre>\(htmlEscape(text))</pre></body></html>"
                try html.write(to: out, atomically: true, encoding: .utf8)
                return ProcessingResult(outputURLs: [out], bytesIn: FileIO.fileSize(at: url), bytesOut: FileIO.fileSize(at: out))
            case .csv where source == .xlsx:
                let out = outputDirectory.appendingPathComponent(base + ".csv")
                try text.write(to: out, atomically: true, encoding: .utf8)
                return ProcessingResult(
                    outputURLs: [out],
                    bytesIn: FileIO.fileSize(at: url),
                    bytesOut: FileIO.fileSize(at: out),
                    notes: ["Flattened XLSX cell text to CSV-like plain text."]
                )
            default:
                break
            }
        }

        if target.isImage || target == .pdf {
            return try await quickLookFallback(url: url, target: target, outputDirectory: outputDirectory)
        }

        throw DocuForgeError.conversionFailed(
            "Cannot convert \(source.displayName) → \(target.displayName). Install LibreOffice for broader Office fidelity, or convert to PDF/TXT."
        )
    }

    private func convertOpenDocument(
        url: URL,
        source: DocumentFormat,
        target: DocumentFormat,
        outputDirectory: URL
    ) async throws -> ProcessingResult {
        if source == .odt, await textUtil.isAvailable(), target.isTextUtilFormat || target == .pdf {
            if target == .pdf {
                let tmp = FileIO.temporaryURL(prefix: "odt", ext: "rtf")
                defer { try? FileManager.default.removeItem(at: tmp) }
                _ = try await textUtil.convert(url: url, to: .rtf, outputURL: tmp)
                return try richTextToPDF(
                    url: tmp,
                    source: .rtf,
                    outputDirectory: outputDirectory,
                    preferredBase: url.deletingPathExtension().lastPathComponent
                )
            }
            let out = outputDirectory.appendingPathComponent(
                url.deletingPathExtension().lastPathComponent + ".\(target.pathExtension)"
            )
            return try await textUtil.convert(url: url, to: target, outputURL: out)
        }

        if await libreOffice.isAvailable {
            return try await libreOffice.convert(url: url, to: target, outputDirectory: outputDirectory)
        }

        // ODP/ODS are ZIP+XML — try crude text extract
        if let text = try? openDocumentText(url: url, source: source), !text.isEmpty {
            let base = url.deletingPathExtension().lastPathComponent
            if target == .txt {
                let out = outputDirectory.appendingPathComponent("\(base).txt")
                try text.write(to: out, atomically: true, encoding: .utf8)
                return ProcessingResult(
                    outputURLs: [out],
                    bytesIn: FileIO.fileSize(at: url),
                    bytesOut: FileIO.fileSize(at: out),
                    notes: ["Extracted OpenDocument text (layout not preserved)."]
                )
            }
            if target == .pdf {
                let out = outputDirectory.appendingPathComponent("\(base).pdf")
                return try HighQualityPDFRenderer.writePlainText(
                    text,
                    to: out,
                    bytesIn: FileIO.fileSize(at: url)
                )
            }
        }

        if target.isImage || target == .pdf {
            return try await quickLookFallback(url: url, target: target, outputDirectory: outputDirectory)
        }

        throw DocuForgeError.conversionFailed(
            "Install LibreOffice for high-fidelity \(source.displayName) conversion, or export PDF from the original app."
        )
    }

    private func convertLegacyOffice(
        url: URL,
        source: DocumentFormat,
        target: DocumentFormat,
        outputDirectory: URL
    ) async throws -> ProcessingResult {
        // DOC is handled by textutil in earlier branch; PPT/XLS land here
        if source == .doc, await textUtil.isAvailable() {
            if target.isTextUtilFormat {
                let out = outputDirectory.appendingPathComponent(
                    url.deletingPathExtension().lastPathComponent + ".\(target.pathExtension)"
                )
                return try await textUtil.convert(url: url, to: target, outputURL: out)
            }
            if target == .pdf {
                let tmp = FileIO.temporaryURL(prefix: "doc", ext: "rtf")
                defer { try? FileManager.default.removeItem(at: tmp) }
                _ = try await textUtil.convert(url: url, to: .rtf, outputURL: tmp)
                return try richTextToPDF(
                    url: tmp,
                    source: .rtf,
                    outputDirectory: outputDirectory,
                    preferredBase: url.deletingPathExtension().lastPathComponent
                )
            }
        }

        if await libreOffice.isAvailable {
            return try await libreOffice.convert(url: url, to: target, outputDirectory: outputDirectory)
        }

        if target.isImage || target == .pdf {
            do {
                return try await quickLookFallback(url: url, target: target, outputDirectory: outputDirectory)
            } catch {
                // continue
            }
        }

        throw DocuForgeError.conversionFailed(
            "\(source.displayName) requires LibreOffice (or Microsoft Office export) for reliable conversion on this Mac. DOC is handled by textutil; legacy PPT/XLS binary formats are not fully parseable with public Apple APIs."
        )
    }

    private func convertIWork(
        url: URL,
        source: DocumentFormat,
        target: DocumentFormat,
        outputDirectory: URL
    ) async throws -> ProcessingResult {
        var errors: [String] = []

        // 1) Apple app automation (high fidelity)
        if let app = IWorkAutomationService.AppKind.forFormat(source), await iwork.isInstalled(app) {
            do {
                let result = try await iwork.export(url: url, source: source, to: target, outputDirectory: outputDirectory)
                // If we got PDF but wanted images, convert further
                if target.isImage, let pdfURL = result.outputURLs.first, DocumentFormat.detect(url: pdfURL) == .pdf {
                    let imagesResult = try await pdf.pdfToImages(url: pdfURL, format: target, outputDirectory: outputDirectory)
                    return ProcessingResult(
                        outputURLs: imagesResult.outputURLs,
                        bytesIn: result.bytesIn,
                        bytesOut: imagesResult.bytesOut,
                        notes: result.notes + ["Rasterized exported PDF to \(target.displayName)."]
                    )
                }
                if target != .pdf,
                   let only = result.outputURLs.first,
                   DocumentFormat.detect(url: only) == .pdf,
                   target.isTextUtilFormat || target == .txt {
                    // try extract from exported PDF
                    return try await convert(url: only, to: target, outputDirectory: outputDirectory)
                }
                return result
            } catch {
                errors.append(error.localizedDescription)
            }
        } else if source.isIWork {
            errors.append("\(source.displayName) app not installed for automation.")
        }

        // 2) Embedded QuickLook/Preview.pdf
        do {
            if let preview = try extractIWorkPreviewPDF(url: url) {
                defer { try? FileManager.default.removeItem(at: preview) }
                var result = try await convert(url: preview, to: target, outputDirectory: outputDirectory)
                return ProcessingResult(
                    outputURLs: result.outputURLs,
                    bytesIn: FileIO.fileSize(at: url),
                    bytesOut: result.bytesOut,
                    notes: ["Used embedded iWork preview PDF."] + result.notes
                )
            }
        } catch {
            errors.append(error.localizedDescription)
        }

        // 3) Quick Look thumbnail
        if target.isImage || target == .pdf {
            do {
                return try await quickLookFallback(url: url, target: target, outputDirectory: outputDirectory)
            } catch {
                errors.append(error.localizedDescription)
            }
        }

        throw DocuForgeError.conversionFailed(
            """
            Could not convert \(source.displayName) → \(target.displayName).
            Tried: iWork automation, embedded preview, Quick Look.
            \(errors.map { "• \($0)" }.joined(separator: "\n"))
            Install/open \(source.displayName.replacingOccurrences(of: " (.*)", with: "", options: .regularExpression)) and grant Automation permission for high-fidelity export.
            """
        )
    }

    private func extractIWorkPreviewPDF(url: URL) throws -> URL? {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            let candidates = [
                url.appendingPathComponent("QuickLook/Preview.pdf"),
                url.appendingPathComponent("preview.pdf")
            ]
            for c in candidates where FileManager.default.fileExists(atPath: c.path) {
                let temp = FileIO.temporaryURL(prefix: "iwork-preview", ext: "pdf")
                try FileManager.default.copyItem(at: c, to: temp)
                return temp
            }
        }
        for key in ["QuickLook/Preview.pdf", "preview.pdf"] {
            if let pdfData = OfficeOpenXML.zipReadOptional(url: url, entry: key) {
                let temp = FileIO.temporaryURL(prefix: "iwork-preview", ext: "pdf")
                try pdfData.write(to: temp)
                return temp
            }
        }
        return nil
    }

    private func quickLookFallback(
        url: URL,
        target: DocumentFormat,
        outputDirectory: URL
    ) async throws -> ProcessingResult {
        let thumbDir = outputDirectory.appendingPathComponent(".ql-\(UUID().uuidString)", isDirectory: true)
        let thumb = try await quickLook.thumbnail(url: url, outputDirectory: thumbDir)
        guard let png = thumb.outputURLs.first else {
            throw DocuForgeError.conversionFailed("Quick Look produced no thumbnail.")
        }
        defer { try? FileManager.default.removeItem(at: thumbDir) }

        if target == .png {
            let out = outputDirectory.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".png")
            try FileManager.default.copyItem(at: png, to: out)
            return ProcessingResult(
                outputURLs: [out],
                bytesIn: FileIO.fileSize(at: url),
                bytesOut: FileIO.fileSize(at: out),
                notes: thumb.notes
            )
        }
        if target.isImage {
            let out = outputDirectory.appendingPathComponent(
                url.deletingPathExtension().lastPathComponent + ".\(target.pathExtension)"
            )
            return try await images.convert(url: png, to: target, outputURL: out)
        }
        if target == .pdf {
            let out = outputDirectory.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".pdf")
            return try await pdf.imagesToPDF(urls: [png], outputURL: out)
        }
        throw DocuForgeError.conversionFailed("Quick Look fallback only supports image/PDF targets.")
    }

    private func fallbackUnknown(
        url: URL,
        target: DocumentFormat,
        outputDirectory: URL
    ) async throws -> ProcessingResult {
        if await libreOffice.isAvailable {
            do {
                return try await libreOffice.convert(url: url, to: target, outputDirectory: outputDirectory)
            } catch {}
        }
        if target.isImage || target == .pdf {
            return try await quickLookFallback(url: url, target: target, outputDirectory: outputDirectory)
        }
        throw DocuForgeError.unsupportedFormat(.unknown)
    }

    private func richTextToPDF(
        url: URL,
        source: DocumentFormat,
        outputDirectory: URL,
        preferredBase: String? = nil
    ) throws -> ProcessingResult {
        let data = try Data(contentsOf: url)
        let options: [NSAttributedString.DocumentReadingOptionKey: Any]
        switch source {
        case .html:
            options = [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue
            ]
        default:
            options = [.documentType: NSAttributedString.DocumentType.rtf]
        }
        let attr = try NSAttributedString(data: data, options: options, documentAttributes: nil)
        let base = url.deletingPathExtension().lastPathComponent
        let outName: String
        if let preferredBase, !preferredBase.isEmpty {
            outName = preferredBase
        } else if base.hasPrefix("tu-") || base.hasPrefix("docx-") || base.hasPrefix("doc-")
                    || base.hasPrefix("odt-") || base.hasPrefix("md-") || base.hasPrefix("tu-rich") {
            outName = "converted"
        } else {
            outName = base
        }
        let out = outputDirectory.appendingPathComponent("\(outName).pdf")
        // Multi-page, style-preserving layout (NSLayoutManager).
        return try HighQualityPDFRenderer.writeAttributedString(
            attr,
            to: out,
            bytesIn: FileIO.fileSize(at: url)
        )
    }

    private func openDocumentText(url: URL, source: DocumentFormat) throws -> String {
        // content.xml for ODT/ODS/ODP
        let data = try OfficeOpenXML.zipRead(url: url, entry: "content.xml")
        let parser = SimpleXMLTextCollector(localNames: ["p", "h", "span", "s"])
        let xml = XMLParser(data: data)
        xml.delegate = parser
        xml.parse()
        // Better: collect text nodes under text:p
        return extractODFText(from: data)
    }

    private func extractODFText(from data: Data) -> String {
        guard let xml = String(data: data, encoding: .utf8) else { return "" }
        // Collect text between tags loosely
        var s = xml
        s = s.replacingOccurrences(of: #"<text:line-break[^/]*/>"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<text:p[^>]*>"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<text:h[^>]*>"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func textUtilSync(url: URL, to target: DocumentFormat, outputURL: URL, bytesIn: Int64) throws -> ProcessingResult {
        let fmt: String
        switch target {
        case .txt: fmt = "txt"
        case .rtf: fmt = "rtf"
        case .html: fmt = "html"
        case .doc: fmt = "doc"
        case .docx: fmt = "docx"
        case .odt: fmt = "odt"
        default: fmt = "txt"
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        process.arguments = ["-convert", fmt, "-output", outputURL.path, url.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw DocuForgeError.conversionFailed("textutil failed for \(target.displayName)")
        }
        return ProcessingResult(
            outputURLs: [outputURL],
            bytesIn: bytesIn,
            bytesOut: FileIO.fileSize(at: outputURL),
            notes: ["Converted with macOS textutil (\(fmt))."]
        )
    }

    private func basicMarkdownToHTML(_ md: String) -> String {
        var lines: [String] = []
        for line in md.components(separatedBy: "\n") {
            if line.hasPrefix("### ") {
                lines.append("<h3>\(htmlEscape(String(line.dropFirst(4))))</h3>")
            } else if line.hasPrefix("## ") {
                lines.append("<h2>\(htmlEscape(String(line.dropFirst(3))))</h2>")
            } else if line.hasPrefix("# ") {
                lines.append("<h1>\(htmlEscape(String(line.dropFirst(2))))</h1>")
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                lines.append("<li>\(htmlEscape(String(line.dropFirst(2))))</li>")
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append("<br/>")
            } else {
                var l = htmlEscape(line)
                // bold **x**
                l = l.replacingOccurrences(of: #"\*\*([^*]+)\*\*"#, with: "<strong>$1</strong>", options: .regularExpression)
                l = l.replacingOccurrences(of: #"\`([^`]+)\`"#, with: "<code>$1</code>", options: .regularExpression)
                lines.append("<p>\(l)</p>")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func htmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func unsupportedMessage(source: DocumentFormat, target: DocumentFormat) -> String {
        """
        Cannot convert \(source.displayName) → \(target.displayName) with available engines.
        Native: PDFKit, ImageIO, textutil, Vision, iWork automation, Quick Look.
        Optional: LibreOffice (not detected).
        See README for the full capability matrix and limitations.
        """
    }

}

/// Minimal XML text collector (used for ODF probing).
private final class SimpleXMLTextCollector: NSObject, XMLParserDelegate, @unchecked Sendable {
    let localNames: Set<String>
    var pieces: [String] = []
    private var capture = false
    private var buffer = ""

    init(localNames: Set<String>) {
        self.localNames = localNames
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
        if localNames.contains(local) { capture = true; buffer = "" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capture { buffer += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
        if localNames.contains(local), capture {
            let t = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { pieces.append(t) }
            capture = false
        }
    }
}
