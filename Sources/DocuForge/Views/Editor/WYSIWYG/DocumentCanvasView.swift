import SwiftUI
import AppKit
import DocuForgeCore

/// WYSIWYG page canvas — objects are real views you select, drag, and edit in place.
struct DocumentCanvasView: View {
    @ObservedObject var session: DocumentEditorSession

    @State private var dragStart: CGPoint?
    @State private var lastDrag: CGPoint?
    @State private var resizing = false
    @State private var resizeStartFrame: CGRect?
    @State private var inlineText: String = ""

    private let handleSize: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            ScrollView([.horizontal, .vertical], showsIndicators: true) {
                ZStack {
                    Color(nsColor: .windowBackgroundColor)
                    if let page = session.currentPage {
                        pageView(page)
                            .scaleEffect(session.zoom, anchor: .topLeading)
                            .frame(
                                width: page.size.width * session.zoom + 80,
                                height: page.size.height * session.zoom + 80,
                                alignment: .topLeading
                            )
                            .padding(40)
                    }
                }
                .frame(minWidth: geo.size.width, minHeight: geo.size.height)
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .onExitCommand {
            session.endTextEdit()
            session.select(id: nil)
        }
    }

    @ViewBuilder
    private func pageView(_ page: DocPage) -> some View {
        ZStack(alignment: .topLeading) {
            // Page surface
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.white)
                .frame(width: page.size.width, height: page.size.height)
                .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
                .overlay(
                    Rectangle()
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    session.canvasClick(at: .zero) // will clear if select tool + empty; handled below
                    // Use simultaneous gesture on page for empty clicks
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onEnded { value in
                            // Click on empty page (not on object) — only if start≈end
                            let p = value.location
                            if hypot(value.translation.width, value.translation.height) < 3 {
                                if session.hitTest(pagePoint: p) == nil {
                                    session.canvasClick(at: p)
                                }
                            }
                        }
                )

            // Objects
            ForEach(page.sortedObjects) { obj in
                objectView(obj, page: page)
            }
        }
        .frame(width: page.size.width, height: page.size.height, alignment: .topLeading)
    }

    @ViewBuilder
    private func objectView(_ obj: CanvasObject, page: DocPage) -> some View {
        let selected = session.selection.contains(obj.id)
        let editing = session.editingTextID == obj.id

        ZStack(alignment: .topLeading) {
            content(for: obj)
                .frame(width: obj.frame.width, height: obj.frame.height, alignment: .topLeading)
                .background(objectBackground(obj, selected: selected, editing: editing))
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 1.5)
                )
                .position(
                    x: obj.frame.midX,
                    y: obj.frame.midY
                )
                .rotationEffect(.degrees(obj.rotation))
                .gesture(objectDragGesture(obj))
                .onTapGesture(count: 2) {
                    session.canvasDoubleClick(at: CGPoint(x: obj.frame.midX, y: obj.frame.midY))
                    if case .text(let t) = obj.kind {
                        inlineText = t.text
                    }
                }
                .onTapGesture(count: 1) {
                    session.canvasClick(at: CGPoint(x: obj.frame.midX, y: obj.frame.midY))
                    if session.tool == .select {
                        session.select(id: obj.id)
                    }
                }

            if selected && !obj.locked && !editing {
                resizeHandle(obj)
            }

            if editing, case .text(let t) = obj.kind {
                TextField("Text", text: Binding(
                    get: { session.textEditDraft },
                    set: { session.textEditDraft = $0 }
                ), axis: .vertical)
                    .font(swiftUIFont(t.style))
                    .foregroundStyle(Color(red: t.style.color.r, green: t.style.color.g, blue: t.style.color.b))
                    .textFieldStyle(.plain)
                    .padding(4)
                    .frame(width: max(40, obj.frame.width), height: max(24, obj.frame.height), alignment: .topLeading)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.95))
                    .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.accentColor, lineWidth: 2))
                    .position(x: obj.frame.midX, y: obj.frame.midY)
                    .onSubmit { session.commitOpenTextEdit() }
            }
        }
    }

    private func objectBackground(_ obj: CanvasObject, selected: Bool, editing: Bool) -> some View {
        Group {
            if editing {
                Color.yellow.opacity(0.08)
            } else if selected {
                Color.accentColor.opacity(0.04)
            } else if case .text = obj.kind {
                Color.clear
            } else {
                Color.clear
            }
        }
    }

    @ViewBuilder
    private func content(for obj: CanvasObject) -> some View {
        switch obj.kind {
        case .text(let t):
            Text(t.text)
                .font(swiftUIFont(t.style))
                .foregroundStyle(Color(red: t.style.color.r, green: t.style.color.g, blue: t.style.color.b))
                .multilineTextAlignment(alignment(t.style.alignment))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(2)
                .opacity(session.editingTextID == obj.id ? 0 : 1)
        case .image(let img):
            if let ns = NSImage(data: img.imageData) {
                Image(nsImage: ns)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Color.gray.opacity(0.2)
            }
        case .shape(let s):
            shapeView(s)
        case .table(let table):
            tableView(table)
        }
    }

    @ViewBuilder
    private func shapeView(_ s: CanvasObject.ShapeContent) -> some View {
        let fill = Color(red: s.fill.r, green: s.fill.g, blue: s.fill.b).opacity(s.fill.a)
        let stroke = Color(red: s.stroke.r, green: s.stroke.g, blue: s.stroke.b).opacity(s.stroke.a)
        switch s.shape {
        case .rectangle:
            RoundedRectangle(cornerRadius: 4)
                .fill(fill)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(stroke, lineWidth: s.strokeWidth))
        case .ellipse:
            Ellipse()
                .fill(fill)
                .overlay(Ellipse().strokeBorder(stroke, lineWidth: s.strokeWidth))
        case .line:
            Path { p in
                p.move(to: CGPoint(x: 0, y: 0.5))
                p.addLine(to: CGPoint(x: 1, y: 0.5))
            }
            .stroke(stroke, lineWidth: s.strokeWidth)
        }
    }

    private func tableView(_ table: CanvasObject.TableContent) -> some View {
        Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            ForEach(0..<table.rows, id: \.self) { r in
                GridRow {
                    ForEach(0..<table.columns, id: \.self) { c in
                        let text = (r < table.cells.count && c < table.cells[r].count)
                            ? table.cells[r][c].text : ""
                        Text(text.isEmpty ? " " : text)
                            .font(.system(size: table.style.fontSize))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .border(Color.secondary.opacity(0.4), width: 0.5)
                            .padding(2)
                    }
                }
            }
        }
    }

    private func resizeHandle(_ obj: CanvasObject) -> some View {
        let x = obj.frame.maxX
        let y = obj.frame.maxY
        return Circle()
            .fill(Color.accentColor)
            .frame(width: handleSize, height: handleSize)
            .position(x: x, y: y)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        session.beginGesture()
                        var f = obj.frame
                        f.size.width = max(20, f.size.width + value.translation.width - (lastDrag.map { value.translation.width - ($0.x) } ?? 0))
                        // simpler: use start frame
                        if resizeStartFrame == nil { resizeStartFrame = obj.frame }
                        if let start = resizeStartFrame {
                            let nf = CGRect(
                                x: start.origin.x,
                                y: start.origin.y,
                                width: max(20, start.width + value.translation.width),
                                height: max(16, start.height + value.translation.height)
                            )
                            session.resizeSelected(to: nf)
                        }
                    }
                    .onEnded { _ in
                        resizeStartFrame = nil
                        session.endGesture()
                    }
            )
    }

    private func objectDragGesture(_ obj: CanvasObject) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard session.tool == .select || session.tool == .text else { return }
                guard !obj.locked else { return }
                if session.editingTextID == obj.id { return }
                if !session.selection.contains(obj.id) {
                    session.select(id: obj.id)
                }
                let prev = lastDrag.map { CGSize(width: $0.x, height: $0.y) } ?? .zero
                let delta = CGSize(
                    width: value.translation.width - prev.width,
                    height: value.translation.height - prev.height
                )
                lastDrag = CGPoint(x: value.translation.width, y: value.translation.height)
                session.dragSelection(by: delta)
            }
            .onEnded { _ in
                lastDrag = nil
                session.endGesture()
            }
    }

    private func swiftUIFont(_ style: TextStyle) -> Font {
        let weight: Font.Weight = style.bold ? .bold : .regular
        return .system(size: style.fontSize, weight: weight)
            .italic(style.italic)
    }

    private func alignment(_ a: TextHAlignment) -> TextAlignment {
        switch a {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

private extension Font {
    func italic(_ on: Bool) -> Font {
        on ? self.italic() : self
    }
}
