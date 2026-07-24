# DocuForge

Native macOS **document toolkit** — convert, merge, split, compress, OCR, passwords, watermarks, page management, and batch jobs.

Built with **Swift**, **SwiftUI**, and first-party Apple frameworks. Processing is **offline-first**. Optional high-fidelity paths use apps you already have (Pages, Keynote, Numbers) or **LibreOffice** if installed.

## Features

| Tool | What it does |
|------|----------------|
| **Convert** | Broad format matrix (documents, slides, sheets, images, EPUB, archives) |
| **Merge / Split** | PDF structure tools |
| **Compress** | Re-encode PDF pages |
| **OCR** | On-device Vision text recognition |
| **Password** | Encrypt / unlock PDFs |
| **Watermark** | Text stamps |
| **Pages** | Reorder, rotate, delete |
| **Batch** | Multi-file pipelines |

Outputs default to `~/Downloads/DocuForge/`.

## Architecture

| Layer | Role |
|--------|------|
| `DocuForge` | SwiftUI shell, drag-and-drop, tools |
| `DocuForgeCore` | Conversion engines and PDF/image/OCR services |

### Engines (priority order)

1. **PDFKit** — PDF ops, PDF ↔ images, text layer extract  
2. **ImageIO / AppKit / sips** — raster images, HEIC, JP2, ICO, limited PSD  
3. **textutil** — DOC, DOCX, ODT, RTF, RTFD, HTML, TXT, WebArchive  
4. **iWork automation** — Pages / Keynote / Numbers export when installed  
5. **Embedded iWork preview** — `QuickLook/Preview.pdf` inside packages  
6. **Quick Look (`qlmanage`)** — preview thumbnails as last resort  
7. **Office Open XML / ODF parsers** — text extract from DOCX/PPTX/XLSX/OD*  
8. **EPUB** — ZIP + XHTML text extract → TXT/HTML/PDF  
9. **Archive tools** — `unzip` / `tar` / `zip`  
10. **LibreOffice (optional)** — headless high-fidelity Office/ODF/legacy PPT/XLS  

## Format support matrix

### Documents

| Format | Read / detect | Convert to PDF | Convert to TXT/HTML/DOC* | Notes |
|--------|---------------|----------------|---------------------------|-------|
| PDF | Yes | — | TXT/HTML (+ textutil chain) | Full PDF toolkit |
| DOC | Yes | Yes (textutil → RTF → PDF) | Yes (textutil) | Native macOS textutil |
| DOCX | Yes | Yes (textutil preferred) | Yes | OOXML text fallback |
| ODT | Yes | Yes (textutil) | Yes (textutil) | |
| RTF / RTFD | Yes | Yes | Yes | |
| TXT | Yes | Yes | Yes | |
| Markdown | Yes | Yes | HTML/TXT/DOC* | Lightweight MD renderer |
| HTML | Yes | Yes | Yes | |
| WebArchive | Yes | via textutil | Yes | |
| Pages | Yes | **High fidelity** via Pages app; else embedded preview / Quick Look | Via export path | Needs Automation permission for app export |

### Presentations

| Format | Support | Notes |
|--------|---------|-------|
| PPTX | Text extract → TXT/PDF; LibreOffice if installed | No public Apple API for full slide layout |
| PPT (legacy) | LibreOffice or Quick Look preview | Binary OLE not fully parseable natively |
| ODP | Text extract / LibreOffice / Quick Look | |
| Keynote | **High fidelity** via Keynote automation; preview/QL fallback | |

### Spreadsheets

| Format | Support | Notes |
|--------|---------|-------|
| XLSX | Cell text extract → TXT/CSV/PDF; LibreOffice optional | Layout not preserved offline |
| XLS (legacy) | LibreOffice / Quick Look | Same limitation as PPT |
| ODS | Text extract / LibreOffice | |
| CSV | TXT/HTML/PDF | |
| Numbers | Automation when installed; preview/QL fallback | |

### Images

| Format | Decode | Encode | Notes |
|--------|--------|--------|-------|
| PNG, JPEG, TIFF, GIF, BMP | Yes | Yes | ImageIO / AppKit |
| HEIC, WebP | Yes | Best-effort | Encode depends on OS codecs |
| JPEG 2000 | Yes | Best-effort | |
| SVG | Rasterize | No vector write | Export PNG/PDF |
| ICO | Yes | Best-effort | Multi-size simplified |
| PSD | Limited | No | Flattened/preview layer via ImageIO |
| AVIF | Best-effort | Best-effort | OS codec dependent |

### Ebook & archives

| Format | Support | Notes |
|--------|---------|-------|
| EPUB | TXT / HTML / PDF | Text extract from spine; layout simplified |
| ZIP | Extract / create | |
| TAR / GZIP | Extract / list | |

## Formats that cannot be fully supported (and why)

| Format / goal | Limitation |
|---------------|------------|
| **Pixel-perfect PPT/PPTX/ODP layout** without LO/iWork | Apple provides no public high-fidelity PowerPoint layout API offline |
| **Legacy PPT / XLS binary** without LibreOffice | Proprietary OLE compounds; textutil does not convert them |
| **Editable PSD layer stacks** | ImageIO exposes composite/preview, not full layer fidelity |
| **SVG as vector output** | Rasterization only for bitmap/PDF targets |
| **DRM-protected EPUB / PDF** | Cannot legally/technically strip DRM |
| **iWork without app + without preview** | Proprietary IWA format; needs Pages/Keynote/Numbers or Quick Look generator |
| **Full Excel formulas / charts** | Text/value extract only offline |
| **Password-protected Office files** | Not decrypted without the password and supporting APIs |

## Permissions

For **Pages / Keynote / Numbers** automation:

**System Settings → Privacy & Security → Automation** — allow DocuForge to control the iWork apps.

First export may prompt; denial falls back to embedded preview / Quick Look.

## Build & run

```bash
cd DocuForge
swift build
swift run DocuForgeVerify   # format + engine verification
swift run DocuForge
./Scripts/package_app.sh
open build/DocuForge.app
```

## Requirements

- macOS 14+  
- Swift 6 / Command Line Tools or Xcode  
- Optional: Pages, Keynote, Numbers, LibreOffice for high-fidelity paths  

## Tests

- `swift run DocuForgeVerify` — comprehensive offline checks (no full Xcode required)  
- `Tests/DocuForgeTests` — XCTest suite when Xcode is available  
