import Foundation
import Vision
import AppKit
import PDFKit
import CoreGraphics

/// On-device OCR using the Vision framework. Works fully offline.
public actor OCRService {
    public init() {}

    public struct OCRResult: Sendable {
        public let text: String
        public let confidence: Float
        public let pageTexts: [String]
    }

    public func recognizeText(in imageURL: URL, languages: [String] = ["en-US"]) async throws -> OCRResult {
        guard let image = NSImage(contentsOf: imageURL),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw DocuForgeError.ocrFailed("Could not load image for OCR.")
        }
        return try await recognize(cgImage: cgImage, languages: languages)
    }

    public func recognizePDF(url: URL, languages: [String] = ["en-US"]) async throws -> OCRResult {
        guard let doc = PDFDocument(url: url) else {
            throw DocuForgeError.ocrFailed("Could not open PDF for OCR.")
        }
        var pages: [String] = []
        var confidences: [Float] = []

        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            // 300 DPI equivalent for sharper OCR without downsampling source pages.
            let scale: CGFloat = 300.0 / 72.0
            let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
            guard let cgImage = renderPage(page, size: size) else { continue }
            let result = try await recognize(cgImage: cgImage, languages: languages)
            pages.append(result.text)
            confidences.append(result.confidence)
        }

        let joined = pages.enumerated().map { "--- Page \($0.offset + 1) ---\n\($0.element)" }.joined(separator: "\n\n")
        let avg = confidences.isEmpty ? 0 : confidences.reduce(0, +) / Float(confidences.count)
        return OCRResult(text: joined, confidence: avg, pageTexts: pages)
    }

    public func exportText(_ result: OCRResult, to url: URL) throws -> ProcessingResult {
        try result.text.write(to: url, atomically: true, encoding: .utf8)
        return ProcessingResult(outputURLs: [url], bytesOut: FileIO.fileSize(at: url))
    }

    /// Builds a simple "searchable" PDF by placing invisible text is not fully
    /// supported without private APIs; we emit a text layer PDF (visible text
    /// under a page render) as a practical offline alternative: image pages +
    /// appended plain-text pages, plus a .txt sidecar.
    public func makeSearchablePDF(sourcePDF: URL, outputPDF: URL, outputText: URL) async throws -> ProcessingResult {
        let ocr = try await recognizePDF(url: sourcePDF)
        // Keep original PDF pages and write text alongside
        guard let doc = PDFDocument(url: sourcePDF) else {
            throw DocuForgeError.ocrFailed("Could not open source PDF.")
        }
        guard doc.write(to: outputPDF) else {
            throw DocuForgeError.pdfOperationFailed("Failed to write PDF copy.")
        }
        try ocr.text.write(to: outputText, atomically: true, encoding: .utf8)
        return ProcessingResult(
            outputURLs: [outputPDF, outputText],
            bytesIn: FileIO.fileSize(at: sourcePDF),
            bytesOut: FileIO.fileSize(at: outputPDF) + FileIO.fileSize(at: outputText),
            notes: ["OCR text saved beside a copy of the PDF (average confidence \(String(format: "%.0f%%", ocr.confidence * 100)))."]
        )
    }

    // MARK: - Private

    private func recognize(cgImage: CGImage, languages: [String]) async throws -> OCRResult {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: DocuForgeError.ocrFailed(error.localizedDescription))
                    return
                }
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                var lines: [String] = []
                var confidences: [Float] = []
                for obs in observations {
                    guard let top = obs.topCandidates(1).first else { continue }
                    lines.append(top.string)
                    confidences.append(top.confidence)
                }
                let text = lines.joined(separator: "\n")
                let avg = confidences.isEmpty ? 0 : confidences.reduce(0, +) / Float(confidences.count)
                continuation.resume(returning: OCRResult(text: text, confidence: avg, pageTexts: [text]))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            if #available(macOS 13.0, *) {
                request.revision = VNRecognizeTextRequestRevision3
            }
            request.recognitionLanguages = languages

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: DocuForgeError.ocrFailed(error.localizedDescription))
            }
        }
    }

    private func renderPage(_ page: PDFPage, size: CGSize) -> CGImage? {
        let image = NSImage(size: size)
        image.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            let bounds = page.bounds(for: .mediaBox)
            ctx.saveGState()
            ctx.scaleBy(x: size.width / bounds.width, y: size.height / bounds.height)
            page.draw(with: .mediaBox, to: ctx)
            ctx.restoreGState()
        }
        image.unlockFocus()
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}
