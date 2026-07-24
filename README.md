# DocuForge

Native macOS document utility — one app for convert, merge, split, compress, OCR, passwords, watermarks, page management, and batch jobs.

Built with **Swift**, **SwiftUI**, and first-party Apple frameworks. Processing is **offline-first**.

## Architecture

| Layer | Responsibility |
|--------|----------------|
| `DocuForge` (executable) | SwiftUI shell, drag-and-drop, tool screens |
| `DocuForgeCore` (library) | PDF/Image/OCR/Conversion/Batch services |

### Native frameworks

- **PDFKit** — merge, split, page ops, encryption, PDF ↔ images
- **Vision** — on-device OCR
- **ImageIO / AppKit** — image decode/encode (PNG, JPEG, HEIC, TIFF, WebP, …)
- **Compression + XMLParser** — Office Open XML text extract (DOCX/PPTX/XLSX)
- **Core Graphics / Core Text** — text → PDF, watermarks, compression renders

### Format support (offline)

| From → To | Capability |
|-----------|------------|
| Images ↔ PDF | Full |
| Images ↔ images | Full (common formats) |
| PDF → text | Embedded text extract; OCR for scans |
| DOCX/PPTX/XLSX → TXT/PDF | Text content (layout flattened) |
| RTF/HTML/TXT → PDF | Yes |
| Pages/Keynote/Numbers | Embedded QuickLook preview when present |
| Full fidelity Office/iWork layout | Not claimed offline — use export from the original app |

## Features

1. **Convert** — multi-file format conversion  
2. **Merge PDF** — ordered combine with drag reorder  
3. **Split PDF** — every page, every N, or custom ranges  
4. **Compress** — page re-encode quality presets  
5. **OCR** — Vision text recognition + export  
6. **Password** — protect / unlock PDFs  
7. **Watermark** — text stamp, position, opacity  
8. **Pages** — reorder, rotate, delete, save  
9. **Batch** — one operation across many files  

Outputs default to `~/Downloads/DocuForge/`.

## Requirements

- macOS 14+  
- Swift 6 / Xcode Command Line Tools (or full Xcode)

## Build & run

```bash
cd DocuForge
swift build
swift run DocuForgeVerify   # offline feature verification (no Xcode XCTest required)
swift run DocuForge
```

Package a `.app` bundle:

```bash
./Scripts/package_app.sh
open build/DocuForge.app
```

## Design decisions

1. **Native only** — no Electron, no cloud conversion APIs for core tools.  
2. **Service actors** — `PDFService`, `OCRService`, etc. isolate work off the main actor.  
3. **Honest Office support** — Open XML text extraction rather than fake pixel-perfect conversion.  
4. **Tool-centric UI** — NavigationSplitView sidebar matching first-party macOS utilities.  
5. **SPM executable + app packaging** — builds with Command Line Tools; script wraps a proper `.app`.

## Tests

`swift test` covers merge, split, compress, password, watermark, page reorder, image convert, text→PDF, and DOCX text extract.
