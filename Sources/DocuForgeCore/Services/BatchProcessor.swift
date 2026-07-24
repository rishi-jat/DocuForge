import Foundation

/// Runs the same operation across many files offline.
public actor BatchProcessor {
    private let pdf = PDFService()
    private let images = ImageService()
    private let ocr = OCRService()
    private let conversion = ConversionService()

    public init() {}

    public struct BatchItemResult: Sendable {
        public let source: URL
        public let success: Bool
        public let outputs: [URL]
        public let errorMessage: String?
    }

    public struct BatchReport: Sendable {
        public let results: [BatchItemResult]
        public let outputDirectory: URL

        public var successCount: Int { results.filter(\.success).count }
        public var failureCount: Int { results.filter { !$0.success }.count }
    }

    public func run(
        urls: [URL],
        operation: BatchOperation,
        quality: CompressQuality = .medium,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async -> BatchReport {
        let dirName: String
        switch operation {
        case .compress: dirName = "Batch-Compress"
        case .ocrToText: dirName = "Batch-OCR"
        case .imagesToPDF: dirName = "Batch-ImagesToPDF"
        case .pdfToPNG: dirName = "Batch-PDFToPNG"
        case .removePassword: dirName = "Batch-Unlock"
        case .convertImagesToJPEG: dirName = "Batch-JPEG"
        }

        let outputDirectory: URL
        do {
            outputDirectory = try FileIO.downloadsOutputDirectory(named: dirName)
        } catch {
            return BatchReport(results: [], outputDirectory: FileManager.default.temporaryDirectory)
        }

        var results: [BatchItemResult] = []
        let total = max(urls.count, 1)

        for (idx, url) in urls.enumerated() {
            progress?(Double(idx) / Double(total), url.lastPathComponent)
            do {
                let outputs = try await processOne(url: url, operation: operation, quality: quality, outputDirectory: outputDirectory)
                results.append(BatchItemResult(source: url, success: true, outputs: outputs, errorMessage: nil))
            } catch {
                results.append(BatchItemResult(source: url, success: false, outputs: [], errorMessage: error.localizedDescription))
            }
        }
        progress?(1, "Done")
        return BatchReport(results: results, outputDirectory: outputDirectory)
    }

    private func processOne(
        url: URL,
        operation: BatchOperation,
        quality: CompressQuality,
        outputDirectory: URL
    ) async throws -> [URL] {
        let base = url.deletingPathExtension().lastPathComponent
        let format = DocumentFormat.detect(url: url)

        switch operation {
        case .compress:
            guard format == .pdf else { throw DocuForgeError.invalidInput("Not a PDF: \(url.lastPathComponent)") }
            let out = outputDirectory.appendingPathComponent("\(base)-compressed.pdf")
            let r = try await pdf.compress(url: url, quality: quality, outputURL: out)
            return r.outputURLs

        case .ocrToText:
            let out = outputDirectory.appendingPathComponent("\(base)-ocr.txt")
            let result: OCRService.OCRResult
            if format == .pdf {
                result = try await ocr.recognizePDF(url: url)
            } else if format.isImage {
                result = try await ocr.recognizeText(in: url)
            } else {
                throw DocuForgeError.invalidInput("OCR supports PDF and images only.")
            }
            let r = try await ocr.exportText(result, to: out)
            return r.outputURLs

        case .imagesToPDF:
            guard format.isImage else { throw DocuForgeError.invalidInput("Not an image: \(url.lastPathComponent)") }
            let out = outputDirectory.appendingPathComponent("\(base).pdf")
            let r = try await pdf.imagesToPDF(urls: [url], outputURL: out)
            return r.outputURLs

        case .pdfToPNG:
            guard format == .pdf else { throw DocuForgeError.invalidInput("Not a PDF: \(url.lastPathComponent)") }
            let sub = outputDirectory.appendingPathComponent(base, isDirectory: true)
            let r = try await pdf.pdfToImages(url: url, format: .png, outputDirectory: sub)
            return r.outputURLs

        case .removePassword:
            throw DocuForgeError.invalidInput("Use the Password tool with the document password to unlock a PDF.")

        case .convertImagesToJPEG:
            guard format.isImage else { throw DocuForgeError.invalidInput("Not an image: \(url.lastPathComponent)") }
            let out = outputDirectory.appendingPathComponent("\(base).jpg")
            let r = try await images.convert(url: url, to: .jpeg, outputURL: out)
            return r.outputURLs
        }
    }
}
